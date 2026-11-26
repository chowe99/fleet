# Active Directory sign-in: the PC joins an on-premises AD domain by itself and staff and students
# sign in with their existing username and password, like a domain-joined Windows PC.
#
# SSSD (AD provider) does identity, authentication and offline caching; adcli does the join; MIT
# Kerberos does the tickets. Opt-in: nothing here applies unless codered.fleet.directory.enable.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.codered.fleet.directory;
  realm = lib.toUpper cfg.domain;
  # AD names are case-insensitive and SSSD hands them out lower-cased (case_sensitive = false),
  # which is what sudo then compares against.
  sudoGroup = g: "%" + lib.replaceStrings [" "] ["\\ "] (lib.toLower g);
  systemctl = "${config.systemd.package}/bin/systemctl";
  dropin = "/var/lib/sssd/conf.d/50-fleet-directory.conf";
in {
  options.codered.fleet.directory = {
    enable = lib.mkEnableOption "joining an Active Directory domain (SSSD + Kerberos)";

    domain = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+";
      example = "school.example.edu";
      description = "The AD DNS domain name. The PC's DNS must point at the domain controllers.";
    };

    joinUser = lib.mkOption {
      type = lib.types.str;
      example = "svc-join";
      description = ''
        Account used to create the computer object. Delegate only "create computer objects"
        on the target OU to it (recommended) instead of using a Domain Admin.
      '';
    };

    joinPasswordFile = lib.mkOption {
      type = lib.types.path;
      example = "/run/agenix/join-password";
      description = ''
        File holding the join account's password, read at runtime by the join service. Deliver it
        as a secret (agenix, sops, the panel); a path that is in the Nix store is world-readable,
        so that is for tests only.
      '';
    };

    computerOu = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "OU=Lab PCs,OU=Computers,DC=school,DC=example,DC=edu";
      description = "OU for the computer object. Null means the domain's default Computers container.";
    };

    adminGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["Fleet Admins"];
      description = "AD groups whose members may use sudo (full root). Spaces in names are fine.";
    };

    gpoAccessControl = lib.mkOption {
      type = lib.types.enum ["disabled" "permissive" "enforcing"];
      default = "permissive";
      description = ''
        What SSSD does with the "Allow/Deny log on locally" Group Policy settings. `permissive`
        evaluates them but only logs a denial, `enforcing` refuses sign-in, `disabled` ignores
        GPOs. Permissive is the default because enforcing needs the GPO files readable over SMB
        and sane service mappings, and a misconfigured policy then locks every user out of every
        PC. Switch to `enforcing` once you have checked the logs (journalctl -u sssd) for
        "denied by GPO" lines you did not expect.
      '';
    };

    ntpServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["dc1.school.example.edu"];
      description = ''
        Time servers (normally the domain controllers). Kerberos fails when the clock is more
        than five minutes off, so a PC must sync to a source that agrees with the domain.
        Empty keeps the system default (systemd-timesyncd with public pool servers).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.hostName == "" || lib.stringLength config.networking.hostName <= 15;
        message = "codered.fleet.directory: hostname `${config.networking.hostName}` is longer than 15 characters, the NetBIOS limit for AD computer names.";
      }
    ];

    services.timesyncd.servers = lib.mkIf (cfg.ntpServers != []) cfg.ntpServers;

    security.krb5 = {
      enable = true;
      settings = {
        libdefaults = {
          default_realm = realm;
          dns_lookup_realm = false;
          dns_lookup_kdc = true;
          rdns = false;
        };
      };
    };

    services.sssd = {
      enable = true;
      settings = {
        sssd = {
          services = "nss, pam";
          domains = cfg.domain;
        };
        nss = {};
        # Offline sign-in never expires (the default, stated so it is a decision).
        pam.offline_credentials_expiration = 0;
        "domain/${cfg.domain}" = {
          id_provider = "ad";
          auth_provider = "ad";
          access_provider = "ad";
          chpass_provider = "ad";
          ad_domain = cfg.domain;
          krb5_realm = realm;
          ldap_id_mapping = true;
          case_sensitive = false;
          use_fully_qualified_names = false;
          fallback_homedir = "/home/%u";
          default_shell = "/run/current-system/sw/bin/bash";
          # Sign-in with the last known password when no domain controller is reachable.
          cache_credentials = true;
          krb5_store_password_if_offline = true;
          ad_gpo_access_control = cfg.gpoAccessControl;
          dyndns_update = false;
          # Fail fast when no domain controller answers. While SSSD still thinks the DC is up, a
          # lookup that waits on it holds up every sign-in; with short timeouts it goes offline
          # in a few seconds and answers from the cache.
          dns_resolver_timeout = 2;
          dns_resolver_op_timeout = 2;
          ldap_network_timeout = 2;
          ldap_opt_timeout = 3;
          ldap_search_timeout = 3;
          krb5_auth_timeout = 4;
        };
      };
    };

    # Domain users get a home on first sign-in (console, ssh, su and the display managers).
    security.pam.services = lib.genAttrs ["login" "su" "sshd" "sddm" "sddm-greeter" "kde" "lightdm" "gdm-password"] (_: {makeHomeDir = true;});

    # school.nix limits the sudo binary to wheel; domain admins are not in wheel, and the sudoers
    # rule below is what decides who may actually use it.
    security.sudo.execWheelOnly = lib.mkIf (cfg.adminGroups != []) (lib.mkForce false);
    security.sudo.extraRules = lib.mkIf (cfg.adminGroups != []) [
      {
        groups = map (g: lib.removePrefix "%" (sudoGroup g)) cfg.adminGroups;
        commands = [
          {
            command = "ALL";
            options = ["SETENV"];
          }
        ];
      }
    ];

    # Joins on its own, retrying until a domain controller answers, and never holds up boot (it is
    # a simple service, not a oneshot that multi-user.target waits for). Idempotent: with a valid
    # keytab it only refreshes SSSD's hostname setting.
    systemd.services.fleet-directory-join = {
      description = "Join the Active Directory domain ${cfg.domain}";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"];
      before = ["sssd.service"];
      path = [pkgs.adcli pkgs.krb5 pkgs.coreutils pkgs.gnugrep];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "30s";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script = ''
        host=$(cat /proc/sys/kernel/hostname)
        host=''${host%%.*}
        if [ -z "$host" ] || [ ''${#host} -gt 15 ]; then
          echo "hostname '$host' is empty or longer than 15 characters (NetBIOS limit); cannot join" >&2
          exit 1
        fi
        name=$(echo "$host" | tr a-z A-Z)

        # SSSD must know the PC's fully qualified name when the hostname is a short one.
        install -d -m 0700 /var/lib/sssd/conf.d
        want="[domain/${cfg.domain}]
        ad_hostname = $host.${cfg.domain}"
        if [ "$(cat ${dropin} 2>/dev/null)" != "$want" ]; then
          printf '%s\n' "$want" > ${dropin}
          changed=1
        fi

        need_join=0
        if ! klist -k /etc/krb5.keytab >/dev/null 2>&1; then
          need_join=1
        elif err=$(kinit -k -c /dev/null "$name\$@${realm}" 2>&1 >/dev/null); then
          :
        elif echo "$err" | grep -qiE 'not found in Kerberos database|Preauthentication failed|integrity check|key version|Cannot find key'; then
          # The computer account was deleted or its password changed: the keytab is stale.
          need_join=1
        fi

        if [ "$need_join" = 1 ]; then
          echo "joining ${cfg.domain} as $name"
          rm -f /etc/krb5.keytab
          adcli join --stdin-password \
            --domain ${cfg.domain} \
            --domain-realm ${realm} \
            --login-user ${lib.escapeShellArg cfg.joinUser} \
            --computer-name "$name" \
            --host-fqdn "$host.${cfg.domain}" \
            --host-keytab /etc/krb5.keytab \
            --os-name "NixOS (CodeRed Fleet)" \
            ${lib.optionalString (cfg.computerOu != null) "--domain-ou ${lib.escapeShellArg cfg.computerOu}"} \
            < ${lib.escapeShellArg cfg.joinPasswordFile}
          changed=1
        fi

        if [ -n "''${changed:-}" ]; then
          ${systemctl} restart --no-block sssd.service
        fi
      '';
    };
  };
}

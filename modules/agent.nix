# Device side of the fleet panel: enrol once, report on every run, and apply
# the target revision the panel asks for.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.codered.fleet.agent;
  inherit (lib) mkOption types;
  state = "/var/lib/fleet-agent";
  # Always single-quoted (lib.escapeShellArg leaves plain words bare).
  quote = s: "'${lib.replaceStrings ["'"] ["'\\''"] (toString s)}'";

  agent = pkgs.writeShellApplication {
    name = "fleet-agent";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.gitMinimal
      config.nix.package
      config.programs.ssh.package
      config.system.build.nixos-rebuild
    ];
    # The token never reaches argv or the journal: request bodies are piped to
    # curl and the Authorization header is read from a file descriptor.
    text = ''
      url=${quote cfg.url}
      profile=${quote cfg.profile}
      flake=${quote cfg.flake}
      group=${quote cfg.group}
      umask 077

      hostname=$(< /proc/sys/kernel/hostname)
      serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || true)
      serial=''${serial:-unknown}

      post() { # post <path> [curl args]; JSON body on stdin, JSON reply on stdout
        local path=$1
        shift
        curl --fail --silent --show-error --max-time 120 \
          -H 'Content-Type: application/json' --data-binary @- "$@" "$url$path"
      }

      if [[ ! -s ${state}/device-token ]]; then
        jq -n --rawfile tok ${quote cfg.enrollTokenFile} \
          --arg hostname "$hostname" --arg serial "$serial" --arg profile "$profile" \
          '{enroll_token: ($tok | sub("\\s+$"; "")), $hostname, $serial, $profile}' |
          post /api/v1/enroll | jq -er .device_token > ${state}/device-token.new
        mv ${state}/device-token.new ${state}/device-token
        echo "enrolled with $url"
      fi

      current_rev() { # of the running system, so it changes after a switch or reboot
        local rev
        rev=$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)
        echo "''${rev:-unknown}"
      }

      report() {
        local last_update=null
        if [[ -s ${state}/last-update.json ]]; then last_update=$(< ${state}/last-update.json); fi
        jq -n --arg hostname "$hostname" --arg serial "$serial" --arg profile "$profile" \
          --arg current_rev "$(current_rev)" \
          --arg nixos_version "$(/run/current-system/sw/bin/nixos-version)" \
          --argjson uptime_s "$(cut -d. -f1 /proc/uptime)" \
          --argjson last_update "$last_update" \
          '{$hostname, $serial, $profile, $current_rev, $nixos_version, $uptime_s, $last_update}' |
          post /api/v1/report -H @<(printf 'Authorization: Bearer %s\n' "$(< ${state}/device-token)")
      }

      target=$(report | jq -r '.target_rev // empty')
      if [[ -z $target || $target == "$(current_rev)" ]]; then
        exit 0
      fi
      if [[ -z $flake || -z $group ]]; then
        echo "panel wants $target, but no flake/group is configured; not applying" >&2
        exit 0
      fi
      # With applyMode=boot a staged update only becomes current after a reboot.
      if [[ -s ${state}/last-update.json ]] &&
        jq -e --arg rev "$target" '.rev == $rev and .ok' ${state}/last-update.json > /dev/null; then
        echo "$target is already staged; waiting for a reboot"
        exit 0
      fi

      ok=false
      if nixos-rebuild ${cfg.applyMode} --flake "$flake?rev=$target#$group"; then ok=true; fi
      jq -n --arg rev "$target" --argjson ok "$ok" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{$rev, $ok, $at}' > ${state}/last-update.json
      report > /dev/null
    '';
  };
in {
  options.codered.fleet.agent = {
    enable = lib.mkEnableOption "the CodeRed Fleet agent, which enrols this PC with the panel and applies updates";
    url = mkOption {
      type = types.str;
      example = "https://fleet.codered.example";
      description = "Base URL of the fleet panel.";
    };
    enrollTokenFile = mkOption {
      type = types.path;
      example = "/var/lib/fleet-agent/enroll-token";
      description = "File holding the enrolment token, used once to obtain this device's token.";
    };
    profile = mkOption {
      type = types.str;
      description = "Profile name reported to the panel (set by the profile module or mkFleet).";
    };
    flake = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "git+https://git.school.example/it/fleet";
      description = "The customer's fleet flake URL. Updates are not applied while this is null.";
    };
    group = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "This PC's nixosConfiguration in `flake` (mkFleet sets it to the group name).";
    };
    applyMode = mkOption {
      type = types.enum ["boot" "switch"];
      default = "boot";
      description = "`boot` stages updates for the next reboot so nothing changes mid-lesson; `switch` applies them at once.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings.experimental-features = ["nix-command" "flakes"];

    systemd.services.fleet-agent = {
      description = "CodeRed Fleet agent";
      wants = ["network-online.target"];
      after = ["network-online.target"];
      restartIfChanged = false; # it may be the one running nixos-rebuild switch
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe agent;
        StateDirectory = "fleet-agent";
        StateDirectoryMode = "0700";
      };
    };

    systemd.timers.fleet-agent = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "15min";
        RandomizedDelaySec = "1min";
      };
    };
  };
}

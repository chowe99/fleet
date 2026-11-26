# Automatic fallback after a bad update. systemd-boot gives a newly staged version a limited number
# of boot attempts ("boot counting"); a boot is good only once `boot-complete.target` is reached, and
# that target needs the required units to be running. A version that fails or hangs is abandoned by
# a restart and the boot loader brings back the last good version, which tells the panel (agent).
#
# The nixpkgs systemd-boot module this flake locks (26.05) has no `bootCounting` option, so the
# counters are put on the boot entries by a hook that runs after every bootloader install.
#
# What happens, in order:
#  1. install hook (`extraInstallCommands`): the version about to become the default boot entry gets a
#     counter ("nixos-generation-N+<tries>.conf") unless it is the running version or already known good.
#     Entries of abandoned versions are removed from the boot menu.
#  2. every boot of a version on trial: the boot loader uses up one try. `fleet-boot-check` passes
#     when every required unit is active; then `boot-complete.target` is reached, systemd-bless-boot
#     removes the counter (the version is good) and the version is remembered as good.
#  3. failure: if the check fails, or the boot is not complete within `bootTimeout` (a unit that never
#     finishes starting, a PC that is up but unhealthy), the PC restarts itself. This happens only
#     while the booted entry still has a counter, so the last good version can never be restarted by it.
#  4. when the tries are used up the boot loader skips that version and boots the next one. On that
#     good boot `fleet-fallback-reconcile` records the version as failed, points the system profile
#     back at the running version (so a later bootloader install cannot make the bad one the default)
#     and writes `last_update.ok = false` for the agent, which also will not stage that revision again.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.codered.fleet.fallback;
  inherit (lib) mkOption types mkIf;
  state = "/var/lib/fleet-fallback";
  esp = config.boot.loader.efi.efiSysMountPoint;
  # systemd-boot sets this EFI variable only when the entry it booted carries a boot counter.
  trialVar = "/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
  profile = "/nix/var/nix/profiles/system";

  # Runs after each bootloader install. Best effort: it must never make an install fail.
  installHook = pkgs.writeShellApplication {
    name = "fleet-fallback-install-hook";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.util-linux];
    text = ''
      entries=${esp}/loader/entries
      [[ -d $entries ]] || exit 0
      default=$(readlink -f "''${1:-/nonexistent}" || true)
      booted=$(readlink -f /run/booted-system 2>/dev/null || true)
      touch ${state}/good ${state}/bad 2>/dev/null || mkdir -p ${state}

      toplevel() { readlink -f ${profile}-"$1"-link 2>/dev/null || true; }
      shopt -s nullglob
      has_counted() { local m=("$entries/nixos-generation-$1"+*.conf); ((''${#m[@]} > 0)); } # bash-minimal has no compgen
      re='^nixos-generation-([0-9]+)(-specialisation-.+)?(\+[0-9]+(-[0-9]+)?)?\.conf$'

      for f in "$entries"/nixos-generation-*.conf; do
        [[ -e $f ]] || continue
        name=''${f##*/}
        [[ $name =~ $re ]] || continue
        n=''${BASH_REMATCH[1]}
        spec=''${BASH_REMATCH[2]}
        counted=''${BASH_REMATCH[3]}
        t=$(toplevel "$n")
        [[ -n $t ]] || continue
        if grep -qxF "$t" ${state}/bad 2>/dev/null && [[ $t != "$booted" ]]; then
          rm -f "$f" # abandoned: not offered in the boot menu
        elif [[ -z $counted ]] && has_counted "$n$spec"; then
          rm -f "$f" # the builder rewrote a plain copy next to the entry that carries the counter
        fi
      done

      # The version about to boot next is on trial unless it is running, or known to be good or bad.
      [[ -n $default && $default != "$booted" ]] || exit 0
      grep -qxF "$default" ${state}/good 2>/dev/null && exit 0
      grep -qxF "$default" ${state}/bad 2>/dev/null && exit 0
      trial=
      for link in ${profile}-*-link; do
        [[ $(readlink -f "$link" || true) == "$default" ]] || continue
        n=''${link#${profile}-}
        n=''${n%-link}
        plain=$entries/nixos-generation-$n.conf
        if [[ -e $plain ]] && ! has_counted "$n"; then
          mv "$plain" "$entries/nixos-generation-$n+${toString cfg.tries}.conf"
        fi
        if has_counted "$n"; then trial=nixos-generation-$n.conf; fi
      done

      # systemd-boot (>= 260) tries the "preferred" entry while it has tries left and otherwise uses
      # "default": name the newest good version there, not a glob, so a specialisation entry or an
      # older bad one can never be picked.
      goodid=
      gens=()
      for link in ${profile}-*-link; do
        n=''${link#${profile}-}
        gens+=("''${n%-link}")
      done
      for n in $(printf '%s\n' "''${gens[@]}" | sort -rn); do
        t=$(toplevel "$n")
        [[ -n $t && -e $entries/nixos-generation-$n.conf ]] || continue
        if [[ $t == "$booted" ]] || { grep -qxF "$t" ${state}/good && ! grep -qxF "$t" ${state}/bad; }; then
          goodid=nixos-generation-$n.conf
          break
        fi
      done
      if [[ -n $trial && -n $goodid && -f ${esp}/loader/loader.conf ]]; then
        grep -vE '^(default|preferred) ' ${esp}/loader/loader.conf > ${esp}/loader/loader.conf.fleet || true
        printf 'preferred %s\ndefault %s\n' "$trial" "$goodid" >> ${esp}/loader/loader.conf.fleet
        mv ${esp}/loader/loader.conf.fleet ${esp}/loader/loader.conf
      fi
      sync -f ${esp} || true
    '';
  };

  check = pkgs.writeShellApplication {
    name = "fleet-boot-check";
    runtimeInputs = [pkgs.coreutils pkgs.systemd];
    text = ''
      failed=0
      units=(${lib.escapeShellArgs cfg.requiredUnits})
      for u in "''${units[@]}"; do
        if ! systemctl is-active --quiet "$u"; then
          echo "required unit $u is not running" >&2
          failed=1
        fi
      done
      if ((failed)); then exit 1; fi
      booted=$(readlink -f /run/booted-system)
      grep -qxF "$booted" ${state}/good 2>/dev/null || echo "$booted" >> ${state}/good
      echo "boot is good: $booted"
    '';
  };

  rebootUnhealthy = pkgs.writeShellApplication {
    name = "fleet-fallback-reboot";
    runtimeInputs = [pkgs.systemd];
    text = ''
      if [[ ! -e ${trialVar} ]]; then
        echo "this boot is not on trial (last good version): not restarting"
        exit 0
      fi
      if systemctl is-active --quiet boot-complete.target; then
        echo "boot completed: nothing to do"
        exit 0
      fi
      echo "this new version did not start properly: restarting so the boot loader can fall back" >&2
      systemctl reboot --no-block
      sleep 60 # a hung shutdown: force it
      systemctl reboot --force
    '';
  };

  reconcile = pkgs.writeShellApplication {
    name = "fleet-fallback-reconcile";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.jq config.nix.package];
    text = ''
      entries=${esp}/loader/entries
      booted=$(readlink -f /run/booted-system)
      touch ${state}/good ${state}/bad ${state}/failed-revs

      rev_of() {
        local rev
        rev=$("$1"/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)
        echo "''${rev:-unknown}"
      }
      toplevel() { readlink -f ${profile}-"$1"-link 2>/dev/null || true; }

      # Versions whose tries are used up (counter "+0-*") and that are not the one running.
      changed=false
      for f in "$entries"/nixos-generation-*+0-*.conf; do
        [[ -e $f ]] || continue
        name=''${f##*/}
        [[ $name =~ ^nixos-generation-([0-9]+)\+0- ]] || continue
        t=$(toplevel "''${BASH_REMATCH[1]}")
        [[ -n $t && $t != "$booted" ]] || continue
        grep -qxF "$t" ${state}/bad && continue
        echo "$t" >> ${state}/bad
        rev=$(rev_of "$t")
        echo "version $t (revision $rev) failed to boot ${toString cfg.tries} times and was abandoned"
        if [[ $rev != unknown ]]; then echo "$rev" >> ${state}/failed-revs; fi
        install -d -m 0700 /var/lib/fleet-agent
        jq -n --arg rev "$rev" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{$rev, ok: false, $at}' \
          > /var/lib/fleet-agent/last-update.json.new
        mv /var/lib/fleet-agent/last-update.json.new /var/lib/fleet-agent/last-update.json
        changed=true
      done

      # Make the running version the one the next boot and later bootloader installs use.
      next=$(readlink -f ${profile} || true)
      if [[ $next != "$booted" ]] && grep -qxF "$next" ${state}/bad; then
        gen=
        for link in ${profile}-*-link; do
          [[ $(readlink -f "$link" || true) == "$booted" ]] || continue
          gen=''${link#${profile}-}
          gen=''${gen%-link}
        done
        if [[ -n $gen ]]; then
          nix-env -p ${profile} --switch-generation "$gen"
        else
          nix-env -p ${profile} --set "$booted"
        fi
        changed=true
      fi
      if $changed; then "$booted"/bin/switch-to-configuration boot; fi
    '';
  };
in {
  options.codered.fleet.fallback = {
    enable = lib.mkEnableOption "automatic fallback to the last good version after a bad update";
    tries = mkOption {
      type = types.ints.positive;
      default = 3;
      description = "How many times a new version may be started before it is abandoned.";
    };
    requiredUnits = mkOption {
      type = types.listOf types.str;
      default =
        lib.optional config.services.displayManager.enable "display-manager.service"
        ++ lib.optional config.codered.fleet.agent.enable "fleet-agent.timer";
      defaultText = lib.literalExpression ''["display-manager.service" "fleet-agent.timer"] (those that exist on this PC)'';
      description = "Units that must be running for a boot to count as good. Keep it to what the PC cannot do without.";
    };
    bootTimeout = mkOption {
      type = types.str;
      default = "10min";
      description = ''
        How long after the kernel starts the boot may take to become good before a version on trial is
        abandoned with a restart. Counts from kernel start, so slow first boots need room.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.loader.systemd-boot.enable;
        message = "codered.fleet.fallback needs systemd-boot (it uses its boot counters).";
      }
    ];

    boot.loader.systemd-boot.extraInstallCommands = ''
      ${lib.getExe installHook} "$@" || true
    '';

    # Reaching this target is what makes a boot good: the multi-user target is up and the checked
    # units are running.
    systemd.targets.boot-complete = {
      wantedBy = ["multi-user.target"];
      after = ["multi-user.target"];
      requires = ["fleet-boot-check.service"];
      wants = ["fleet-fallback-reconcile.service"];
    };

    systemd.services = {
      fleet-boot-check = {
        description = "Check that the required units are running (a good boot)";
        wants = cfg.requiredUnits;
        after = cfg.requiredUnits ++ ["multi-user.target"];
        onFailure = ["fleet-fallback-reboot.service"];
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe check;
          StateDirectory = "fleet-fallback";
        };
      };

      fleet-fallback-reboot = {
        description = "Restart a new version that did not start properly";
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe rebootUnhealthy;
        };
      };

      fleet-fallback-reconcile = {
        description = "Record a version that was abandoned and fell back to the last good one";
        after = ["fleet-boot-check.service"];
        before = ["boot-complete.target" "fleet-agent.service"];
        restartIfChanged = false;
        stopIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe reconcile;
          StateDirectory = "fleet-fallback";
        };
      };
    };

    # A boot that is not good within bootTimeout restarts, but only a version still on trial.
    systemd.timers.fleet-boot-timeout = {
      description = "Abandon a new version that has not finished starting";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.bootTimeout;
        Unit = "fleet-fallback-reboot.service";
      };
    };

    # Where the PC has a hardware watchdog, a hung boot or a wedged systemd restarts the PC.
    systemd.settings.Manager = {
      RuntimeWatchdogSec = lib.mkDefault "1min";
      RebootWatchdogSec = lib.mkDefault "5min";
    };
    # A kernel panic restarts instead of waiting for someone to look at the screen.
    boot.kernelParams = ["panic=10"];
  };
}

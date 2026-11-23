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
      pkgs.util-linux # lscpu, the CPU-name fallback
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

      rev_of() { # rev_of <system>: the revision it was built from
        local rev
        rev=$("$1"/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)
        echo "''${rev:-unknown}"
      }
      current_rev() { rev_of /run/current-system; } # changes after a switch or reboot

      num() { [[ ''${1:-} =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

      # The PC's hardware as JSON. Never fails: anything unreadable becomes "", 0 or null.
      hardware() {
        local vendor model ver cpu k v out ram=0 size avail total=0 free=0 bat full design cycles health
        vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
        model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
        if [[ $vendor == LENOVO* ]]; then # product_name is a part number; product_version is "ThinkPad T480"
          ver=$(cat /sys/class/dmi/id/product_version 2>/dev/null || true)
          model=''${ver:-$model}
        fi
        cpu=
        while IFS=: read -r k v; do
          if [[ $k == "model name"* ]]; then cpu=$v; break; fi
        done < /proc/cpuinfo 2>/dev/null || true
        if [[ -z $cpu ]]; then
          out=$(lscpu 2>/dev/null || true)
          while IFS=: read -r k v; do
            if [[ $k == "Model name"* ]]; then cpu=$v; break; fi
          done <<< "$out"
        fi
        while read -r k v _; do
          if [[ $k == MemTotal: ]]; then ram=$(($(num "$v") / 1024)); break; fi
        done < /proc/meminfo 2>/dev/null || true
        read -r size avail < <(df -B1 --output=size,avail / 2>/dev/null | tail -n1) || true
        total=$(($(num "''${size:-}") / 1073741824))
        free=$(($(num "''${avail:-}") / 1073741824))

        bat=null
        for b in /sys/class/power_supply/BAT*; do
          [[ -d $b ]] || continue
          full=$(cat "$b/energy_full" 2>/dev/null || cat "$b/charge_full" 2>/dev/null || true)
          design=$(cat "$b/energy_full_design" 2>/dev/null || cat "$b/charge_full_design" 2>/dev/null || true)
          cycles=$(cat "$b/cycle_count" 2>/dev/null || true)
          full=$(num "$full")
          design=$(num "$design")
          health=0
          if ((design > 0)); then health=$((full * 100 / design)); fi
          if ((health > 100)); then health=100; fi
          bat=$(jq -n --argjson h "$health" --argjson c "$(num "$cycles")" '{health_pct: $h, cycle_count: $c}')
          break
        done

        jq -n --arg vendor "$vendor" --arg model "$model" --arg cpu "$cpu" \
          --argjson ram_mb "$ram" --argjson disk_total_gb "$total" --argjson disk_free_gb "$free" \
          --argjson battery "$bat" \
          'def clean: gsub("^\\s+|\\s+$"; "") | .[0:255];
           {vendor: ($vendor | clean), model: ($model | clean), cpu: ($cpu | clean),
            $ram_mb, $disk_total_gb, $disk_free_gb, $battery}'
      }

      report() {
        local hw
        hw=$(hardware 2>/dev/null) || hw=null
        local last_update=null
        if [[ -s ${state}/last-update.json ]]; then last_update=$(< ${state}/last-update.json); fi
        jq -n --arg hostname "$hostname" --arg serial "$serial" --arg profile "$profile" \
          --arg current_rev "$(current_rev)" \
          --arg nixos_version "$(/run/current-system/sw/bin/nixos-version)" \
          --argjson uptime_s "$(cut -d. -f1 /proc/uptime)" \
          --argjson last_update "$last_update" --argjson hardware "$hw" \
          '{$hostname, $serial, $profile, $current_rev, $nixos_version, $uptime_s, $last_update}
           + (if $hardware == null then {} else {$hardware} end)' |
          post /api/v1/report -H @<(printf 'Authorization: Bearer %s\n' "$(< ${state}/device-token)")
      }

      target=$(report | jq -r '.target_rev // empty')
      # Compare with what the next boot runs (the system profile), not the running system: with
      # applyMode=boot a staged update only becomes current after a reboot, and a ring moved back
      # to the running revision must un-stage it.
      next_boot=$(rev_of /nix/var/nix/profiles/system)
      if [[ -z $target || $target == "$next_boot" ]]; then
        if [[ -n $target && $target != "$(current_rev)" ]]; then echo "$target is staged; waiting for a reboot"; fi
        exit 0
      fi
      if [[ -z $flake || -z $group ]]; then
        echo "panel wants $target, but no flake/group is configured; not applying" >&2
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

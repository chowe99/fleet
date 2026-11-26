# Device side of the fleet panel: enrol once, report on every run, apply the
# target revision the panel asks for, and carry out remote actions (README: "Remote actions").
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.codered.fleet.agent;
  inherit (lib) mkOption types;
  state = "/var/lib/fleet-agent";
  lockedFile = "${state}/locked"; # present while the panel has this PC locked
  nologinText = "This PC has been locked by your IT administrator. Please contact them.";
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
      pkgs.systemd # loginctl, systemctl
      pkgs.cryptsetup # wipe
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
      flake_template=${quote cfg.flakeUrlTemplate}
      group=${quote cfg.group}
      allow_wipe=${lib.boolToString cfg.allowWipe}
      wipe_device=${quote (lib.optionalString (cfg.encryptedDevice != null) cfg.encryptedDevice)}
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

      # nix authenticates to the panel (config tarballs) with the device token via a private netrc.
      # Rewritten every run so it follows token changes; the token is never printed.
      host=''${url#*://}
      host=''${host%%/*}
      host=''${host##*@}
      if [[ $host == \[* ]]; then host=''${host%%]*}; host=''${host#[}; else host=''${host%%:*}; fi
      printf 'machine %s login device password %s\n' "$host" "$(< ${state}/device-token)" > ${state}/netrc.new
      mv ${state}/netrc.new ${state}/netrc

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

      # Results of remote actions to send with the next report: a JSON array of {id, status, detail?}.
      # Ones carried over a reboot are kept in pending-results.json until a report has delivered them.
      results='[]'
      carried=false
      if [[ -s ${state}/pending-results.json ]]; then
        if jq -ec 'if type == "array" then . else error("not an array") end' ${state}/pending-results.json > ${state}/pending-results.tmp 2>/dev/null; then
          results=$(< ${state}/pending-results.tmp)
          carried=true
        fi
        rm -f ${state}/pending-results.tmp
      fi

      add_result() { # add_result <id> <done|failed|deferred> [detail]
        results=$(jq -c --arg id "$1" --arg status "$2" --arg detail "''${3:-}" \
          '. + [{$id, $status} + (if $detail == "" then {} else {detail: $detail[0:255]} end)] | .[-20:]' <<< "$results")
      }

      # Locked: every login but root's is refused (pam_nologin reads /run/nologin) until "unlock".
      # The state file survives reboots; fleet-lock.service puts /run/nologin back at boot.
      is_locked() { [[ -e ${lockedFile} ]]; }
      block_logins() { printf '%s\n' ${quote nologinText} > /run/nologin; }
      if is_locked && [[ ! -e /run/nologin ]]; then block_logins; fi

      report() {
        local hw locked=false
        if is_locked; then locked=true; fi
        hw=$(hardware 2>/dev/null) || hw=null
        local last_update=null
        if [[ -s ${state}/last-update.json ]]; then last_update=$(< ${state}/last-update.json); fi
        jq -n --arg hostname "$hostname" --arg serial "$serial" --arg profile "$profile" \
          --arg current_rev "$(current_rev)" \
          --arg nixos_version "$(/run/current-system/sw/bin/nixos-version)" \
          --argjson uptime_s "$(cut -d. -f1 /proc/uptime)" \
          --argjson last_update "$last_update" --argjson hardware "$hw" --argjson results "$results" \
          --argjson locked "$locked" \
          '{$hostname, $serial, $profile, $current_rev, $nixos_version, $uptime_s, $last_update, $locked}
           + (if $hardware == null then {} else {$hardware} end)
           + (if ($results | length) == 0 then {} else {action_results: $results} end)' |
          post /api/v1/report -H @<(printf 'Authorization: Bearer %s\n' "$(< ${state}/device-token)")
      }

      reply=$(report)
      if $carried; then # the panel has them now
        rm -f ${state}/pending-results.json
        results='[]'
      fi
      target=$(jq -r '.target_rev // empty' <<< "$reply")

      updated=false
      stage_status=current # current | ok (just staged) | failed | noconfig
      stage() {
        # Compare with what the next boot runs (the system profile), not the running system: with
        # applyMode=boot a staged update only becomes current after a reboot, and a ring moved back
        # to the running revision must un-stage it.
        local next_boot
        next_boot=$(rev_of /nix/var/nix/profiles/system)
        if [[ -z $target || $target == "$next_boot" ]]; then
          if [[ -n $target && $target != "$(current_rev)" ]]; then echo "$target is staged; waiting for a reboot"; fi
          return 0
        fi
        if [[ -z $group || ( -z $flake && -z $flake_template ) ]]; then
          echo "panel wants $target, but no flake/group is configured; not applying" >&2
          stage_status=noconfig
          return 0
        fi
        # A revision the PC already fell back from (fleet-fallback) is not staged again; the panel's
        # target has to move to a new revision.
        if grep -qxF -- "$target" /var/lib/fleet-fallback/failed-revs 2>/dev/null; then
          echo "$target failed to start on this PC and was abandoned; not staging it again" >&2
          stage_status=failed
          return 0
        fi
        local ok=false src
        if [[ ! $target =~ ^[0-9a-f]{6,40}$ ]]; then
          echo "panel sent an invalid target revision; not applying" >&2
          stage_status=failed
          return 0
        fi
        if [[ -n $flake_template ]]; then src=''${flake_template//'{rev}'/$target}; else src="$flake?rev=$target"; fi
        if nixos-rebuild ${cfg.applyMode} --flake "$src#$group"; then ok=true; stage_status=ok; else stage_status=failed; fi
        jq -n --arg rev "$target" --argjson ok "$ok" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{$rev, $ok, $at}' > ${state}/last-update.json
        updated=true
      }
      stage

      # Nobody is logged in when no logind session has Class=user. If that can't be told, assume someone is.
      idle() {
        local sessions id class
        sessions=$(loginctl list-sessions --no-legend 2>/dev/null) || return 1
        while read -r id _; do
          [[ -n $id ]] || continue
          class=$(loginctl show-session "$id" --property=Class --value 2>/dev/null) || return 1
          if [[ $class == user ]]; then return 1; fi
        done <<< "$sessions"
        return 0
      }

      reboot_now() { # reboot_now <id>: remember "done" across the reboot, then go
        add_result "$1" "done" "rebooting"
        jq -c . <<< "$results" > ${state}/pending-results.tmp
        mv ${state}/pending-results.tmp ${state}/pending-results.json
        sync
        systemctl reboot --no-block
        exit 0
      }

      # End every non-root user session (the display manager's greeter is not one).
      end_sessions() {
        local id uid class uids=() rc=0
        while read -r id _; do
          [[ -n $id ]] || continue
          class=$(loginctl show-session "$id" --property=Class --value 2>/dev/null) || continue
          uid=$(loginctl show-session "$id" --property=User --value 2>/dev/null) || continue
          if [[ $class == user* && $uid != 0 ]]; then uids+=("$uid"); fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
        for uid in $(printf '%s\n' "''${uids[@]}" | sort -u); do
          loginctl terminate-user "$uid" || rc=1
        done
        return "$rc"
      }

      lock_now() { # lock_now <id>
        date -u +%Y-%m-%dT%H:%M:%SZ > ${lockedFile}.tmp
        mv ${lockedFile}.tmp ${lockedFile}
        sync
        block_logins
        if end_sessions; then
          add_result "$1" "done" "logins blocked and every session ended; root can still log in"
        else
          add_result "$1" "failed" "logins are blocked, but some sessions could not be ended; send lock again"
        fi
      }

      unlock_now() { # unlock_now <id>
        rm -f ${lockedFile} /run/nologin
        sync
        add_result "$1" "done" "logins allowed again"
      }

      # Wipe: report "done" first (the panel must know before the keys are gone; if that report fails,
      # nothing is wiped and the action comes again), then destroy every LUKS keyslot, then power off.
      wipe_now() { # wipe_now <id>
        add_result "$1" "done" "destroying every disk key, then powering off"
        report > /dev/null
        if cryptsetup erase --batch-mode "$wipe_device"; then
          echo "wiped: every keyslot of $wipe_device is destroyed; powering off"
          sync
          systemctl poweroff --no-block --check-inhibitors=no
          exit 0
        fi
        results=$(jq -c --arg id "$1" 'map(select(.id != $id))' <<< "$results")
        add_result "$1" "failed" "destroying the disk keys failed; the PC is NOT wiped"
      }

      actions=$(jq -r '[.actions[]? | select(type == "object" and (.id | type) == "string" and .id != "")]
        | .[] | [.id, (.type | tostring), (.force == true)] | @tsv' <<< "$reply" 2>/dev/null || true)
      while IFS=$'\t' read -r id type force; do
        [[ -n $id ]] || continue
        case $type in
          reboot | update_now)
            if [[ $type == update_now && $stage_status == failed ]]; then
              add_result "$id" "failed" "the update could not be staged; see the PC's last update"
            elif [[ $type == update_now && $stage_status == noconfig ]]; then
              add_result "$id" "failed" "no flake/group configured on this PC; cannot update"
            elif [[ $force == true ]] || idle; then
              reboot_now "$id"
            else
              add_result "$id" "deferred" "someone is logged in"
            fi
            ;;
          lock) lock_now "$id" ;;
          unlock) unlock_now "$id" ;;
          wipe)
            if [[ $allow_wipe != true ]]; then
              add_result "$id" "failed" "wiping is not allowed on this PC (codered.fleet.agent.allowWipe is off)"
            elif [[ -z $wipe_device ]]; then
              add_result "$id" "failed" "this PC has no disk encryption, so it cannot be wiped remotely"
            elif ! is_locked; then
              add_result "$id" "failed" "lock the PC before wiping it"
            elif ! cryptsetup isLuks "$wipe_device" 2>/dev/null; then
              add_result "$id" "failed" "the encrypted disk ($wipe_device) was not found"
            else
              wipe_now "$id"
            fi
            ;;
          *) add_result "$id" "failed" "unknown action type" ;;
        esac
      done <<< "$actions"

      # Tell the panel about the update and any action outcomes without waiting for the next timer run.
      if $updated || [[ $results != '[]' ]]; then report > /dev/null; fi
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
    flakeUrlTemplate = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://fleet.codered.lol/api/v1/config/{rev}.tar.gz";
      description = ''
        Where to fetch the config for a target revision; `{rev}` is replaced by it. Takes precedence
        over `flake`. For panel-hosted config nix authenticates with the device token via a netrc.
      '';
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
    allowWipe = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether the panel's "wipe" action may destroy this PC's disk keys (only while the PC is locked,
        and only with codered.fleet.encryption on). Off by default: a wipe cannot be undone.
      '';
    };
    encryptedDevice = mkOption {
      type = types.nullOr types.str;
      default = null;
      internal = true;
      description = "The LUKS volume a wipe erases; set by codered.fleet.encryption.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings.experimental-features = ["nix-command" "flakes"];
    nix.settings.netrc-file = "${state}/netrc";

    # Remote lock: NixOS's PAM stacks have no pam_nologin, so add it first in the account stack (before
    # any `sufficient` module could end it early). In account, not auth: the password is still asked
    # for, then refused. sddm (and sddm-autologin, gdm) include `login`'s account stack.
    security.pam.services = let
      nologin = svc: {
        rules.account.fleet-nologin = {
          control = "required";
          modulePath = "${config.security.pam.package}/lib/security/pam_nologin.so";
          order =
            lib.foldl' lib.min 10000 (map (r: r.order)
              (lib.attrValues (removeAttrs config.security.pam.services.${svc}.rules.account ["fleet-nologin"])))
            - 10;
        };
      };
    in
      lib.mkMerge [
        {login = nologin "login";}
        (lib.mkIf config.services.openssh.enable {sshd = nologin "sshd";})
        (lib.mkIf config.services.xserver.displayManager.lightdm.enable {
          lightdm = nologin "lightdm";
          lightdm-autologin = nologin "lightdm-autologin";
        })
        (lib.mkIf config.services.greetd.enable {greetd = nologin "greetd";})
      ];

    # systemd-user-sessions removes /run/nologin at boot: put it back before anyone can log in.
    systemd.services.fleet-lock = {
      description = "Keep a remotely locked PC locked across reboots";
      wantedBy = ["multi-user.target"];
      wants = ["getty-pre.target"];
      after = ["systemd-user-sessions.service"];
      before = ["getty-pre.target" "display-manager.service" "sshd.service"];
      unitConfig.ConditionPathExists = lockedFile;
      serviceConfig.Type = "oneshot";
      script = "printf '%s\\n' ${quote nologinText} > /run/nologin";
    };

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

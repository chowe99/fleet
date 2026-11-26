# BitLocker-style disk encryption for the root file system (README: "Disk encryption").
#
# A PC arrives from the image as LUKS2 opened by the image's shared, public key. On first boot
# fleet-encryption.service replaces the volume key (online re-encryption), enrols the TPM2 (PCR 7),
# makes a recovery key, escrows it with the panel using the agent's device token, and only then
# removes the image key. Until every step has worked the image key stays, so a PC is never locked out.
#
# Unlock order at boot (systemd initrd):
#   1. fleet-image-key.service tries the image key (first boot only; it fails fast once removed).
#   2. systemd-cryptsetup@<name>.service: the TPM2 token, then the recovery-key prompt.
# The image key is deliberately NOT the crypttab key file: with `tpm2-device=` set, systemd-cryptsetup
# reads a key file as a TPM2-sealed blob and never looks at the LUKS2 TPM2 token, so once the image key
# was removed every boot would stop at a password prompt.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.codered.fleet.encryption;
  agent = config.codered.fleet.agent;
  inherit (lib) mkOption types;
  # Always single-quoted (lib.escapeShellArg leaves plain words bare).
  quote = s: "'${lib.replaceStrings ["'"] ["'\\''"] (toString s)}'";

  pcrs = lib.concatMapStringsSep "+" toString cfg.tpm2Pcrs;
  initrdKey = "/etc/fleet/image.key";
  deviceUnit = "${utils.escapeSystemdPath cfg.device}.device";
  cryptsetupUnit = "systemd-cryptsetup@${utils.escapeSystemdPath cfg.mapperName}.service";
  # Activation options shared by both unlock paths, so the mapping is the same whichever key opened it.
  activation = lib.optional cfg.initrdLuksDevice.allowDiscards "discard";

  enrol = pkgs.writeShellApplication {
    name = "fleet-encryption";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.cryptsetup
      pkgs.curl
      pkgs.gnugrep
      pkgs.jq
      config.systemd.package # systemd-cryptenroll, systemd-analyze, systemd-ac-power
    ];
    # The recovery key only ever lives in this process's memory: it reaches cryptsetup, jq and curl
    # through pipes from bash builtins, never argv, a file, or the journal.
    text = ''
      dev=${quote cfg.device}
      image_key=${quote cfg.imageKeyFile}
      url=${quote agent.url}
      pcrs=${quote pcrs}
      token_file=/var/lib/fleet-agent/device-token
      plugins=${quote "${config.systemd.package}/lib/cryptsetup"}
      rt=''${RUNTIME_DIRECTORY:-/run/fleet-encryption}
      umask 077

      last=
      say() { # log once per change of state, not once per retry
        if [[ $* != "$last" ]]; then
          echo "$*"
          last=$*
        fi
      }

      m= # the LUKS2 header as JSON
      refresh() { m=$(cryptsetup luksDump --dump-json-metadata "$dev"); }
      # Keyslots bound to a token type, one per line.
      slots_of() { jq -r --arg t "$1" '[.tokens[] | select(.type == $t) | .keyslots[]] | unique | .[]' <<< "$m"; }
      # Our own progress, kept in the header next to the keys it describes (token type "codered-fleet").
      state() { jq -r --arg k "$1" '.tokens[] | select(.type == "codered-fleet") | .[$k] // empty' <<< "$m" | head -n1; }
      state_set() { # state_set <jq filter>: update our token, then re-read the header
        local cur id args=()
        cur=$(jq -c '.tokens | to_entries | map(select(.value.type == "codered-fleet")) | first // {key: null, value: {type: "codered-fleet", keyslots: []}}' <<< "$m") || return 1
        id=$(jq -r '.key // empty' <<< "$cur")
        if [[ -n $id ]]; then args=(--token-id "$id" --token-replace); fi
        jq -c ".value | $1" <<< "$cur" | cryptsetup token import --json-file=- "''${args[@]}" "$dev" || return 1
        refresh
      }

      image_key_opens() { cryptsetup open --test-passphrase --key-file="$image_key" "$dev" > /dev/null 2>&1; }
      tpm_present() { systemd-analyze has-tpm2 > /dev/null 2>&1; }
      # Proof, not presence: the TPM2 token really yields the volume key in this boot's PCR state.
      # (nixpkgs' cryptsetup finds token plugins on the library path, not --external-tokens-path.)
      tpm_unlocks() {
        LD_LIBRARY_PATH=$plugins cryptsetup open --test-passphrase --token-only --token-type=systemd-tpm2 \
          "$dev" > /dev/null 2>&1
      }
      enrol_tpm() {
        say "enrolling the TPM2 (PCR $pcrs)"
        systemd-cryptenroll --unlock-key-file="$image_key" --tpm2-device=auto --tpm2-pcrs="$pcrs" \
          --tpm2-public-key= --tpm2-pcrlock= "$dev" || return 1
        refresh
      }
      escrowed_slot() { # the recovery keyslot the panel holds the key for, if it still exists
        local slot
        slot=$(jq -r '[.tokens[] | select(.type == "codered-fleet" and .recovery_escrowed == true) | .recovery_keyslot] | first // empty' <<< "$m")
        [[ -n $slot ]] || return 1
        jq -e --arg s "$slot" '(.keyslots | has($s)) and any(.tokens[]; .type == "systemd-recovery" and (.keyslots | index($s)) != null)' <<< "$m" > /dev/null || return 1
        echo "$slot"
      }
      on_mains() {
        if systemd-ac-power; then return 0; fi
        say "on battery: waiting for mains power before re-encrypting the disk"
        return 1
      }

      recovery_key= # set only between enrolling a recovery key and the panel confirming it
      recovery_slot=
      tpm_reenrolled=

      # A recovery key we made but could not escrow before this process started is unknown to everyone
      # (it only ever lived in a previous process's memory): remove its keyslot.
      discard_unescrowed() {
        local slot
        slot=$(jq -r '[.tokens[] | select(.type == "codered-fleet" and .recovery_escrowed != true) | .recovery_keyslot // empty] | first // empty' <<< "$m")
        [[ -n $slot ]] || return 0
        if slots_of systemd-recovery | grep -qx "$slot"; then
          say "removing recovery keyslot $slot: it was never escrowed"
          systemd-cryptenroll --wipe-slot="$slot" "$dev" || return 1
          refresh || return 1
        fi
        state_set 'del(.recovery_keyslot, .recovery_escrowed)'
      }

      new_recovery_key() {
        local before key slot
        before=$(slots_of systemd-recovery)
        # C locale and no colours: systemd-cryptenroll then never draws the key as a QR code on stderr.
        # stdout carries only the key; stderr (no key) goes to a root-only tmpfs file, shown on failure.
        if ! key=$(LC_ALL=C SYSTEMD_COLORS=0 systemd-cryptenroll --unlock-key-file="$image_key" --recovery-key "$dev" 2> "$rt/enrol.err"); then
          echo "could not enrol a recovery key:" >&2
          cat "$rt/enrol.err" >&2
          return 1
        fi
        refresh || return 1
        slot=$(comm -13 <(sort <<< "$before") <(slots_of systemd-recovery | sort) | head -n1)
        if [[ -z $slot ]]; then
          echo "enrolled a recovery key but could not find its keyslot" >&2
          return 1
        fi
        # Mark it as ours and not yet escrowed before anything else can fail, so a later run can remove it.
        state_set ".recovery_keyslot = \"$slot\" | .recovery_escrowed = false" || return 1
        if [[ ! $key =~ ^[cbdefghijklnrtuv]{8}(-[cbdefghijklnrtuv]{8}){7}$ ]]; then
          echo "systemd-cryptenroll printed something that is not a recovery key; discarding keyslot $slot" >&2
          discard_unescrowed
          return 1
        fi
        recovery_key=$key
        recovery_slot=$slot
        say "made a recovery key (keyslot $slot); escrowing it with the panel"
      }

      recovery_key_opens() {
        printf '%s' "$recovery_key" | cryptsetup open --test-passphrase --key-slot="$recovery_slot" --key-file=- "$dev" > /dev/null 2>&1
      }

      have_token() {
        if [[ -s $token_file ]]; then return 0; fi
        say "waiting for the fleet agent to enrol: the recovery key is escrowed with its device token"
        return 1
      }

      escrow() {
        local uuid reply code err
        have_token || return 1
        uuid=$(cryptsetup luksUUID "$dev") || return 1
        reply=$(printf '%s' "$recovery_key" | jq -Rs --arg luks_uuid "$uuid" '{recovery_key: ., $luks_uuid}' |
          curl --silent --show-error --max-time 60 -w '\n%{http_code}' -H 'Content-Type: application/json' \
            -H @<(printf 'Authorization: Bearer %s\n' "$(< "$token_file")") \
            --data-binary @- "$url/api/v1/escrow" 2> "$rt/escrow.err") || true
        code=''${reply##*$'\n'}
        if [[ $code == 200 ]] && jq -e '.ok == true' <<< "''${reply%$'\n'*}" > /dev/null 2>&1; then
          return 0
        fi
        err=$(head -c 200 "$rt/escrow.err" | tr '\n' ' ')
        say "the panel has not taken the recovery key (HTTP ''${code:-none}''${err:+, $err}); the image key stays until it does, retrying every minute"
        return 1
      }

      done_summary() {
        local tpm=no rec=no
        if [[ -n $(slots_of systemd-tpm2) ]]; then tpm=yes; fi
        if escrowed_slot > /dev/null; then rec=yes; fi
        if [[ $tpm == yes && $rec == yes ]]; then
          say "disk encryption is set up: the TPM2 (PCR $pcrs) unlocks $dev, the panel holds its recovery key, the image key is gone"
        else
          say "the image key no longer opens $dev (TPM2 enrolled: $tpm, escrowed recovery key: $rec); nothing to do automatically"
        fi
      }

      # One pass. 0: finished (now or earlier). 1: not yet; try again in a minute.
      # Called only as an `if` condition, where bash ignores errexit: every step checks for itself.
      run_once() {
        if ! cryptsetup isLuks --type luks2 "$dev" > /dev/null 2>&1; then
          say "$dev is not a LUKS2 volume; check codered.fleet.encryption.device"
          return 1
        fi
        refresh || return 1
        if ! image_key_opens; then
          done_summary
          return 0
        fi
        if ! tpm_present; then
          say "no usable TPM2 ($(systemd-analyze has-tpm2 2>&1 | tr '\n' ' ')): keeping the image key, so this disk is NOT protected yet; turn the TPM (fTPM/PTT) on in the firmware settings"
          return 1
        fi

        # 1. A volume key of this PC's own: the image's was shared by every PC flashed from it.
        #    Online and resumable: progress lives in the LUKS2 header and survives a crash or power cut.
        if jq -e '.config.requirements.mandatory // [] | any(startswith("online-reencrypt"))' <<< "$m" > /dev/null; then
          on_mains || return 1
          say "resuming the replacement of the volume key"
          cryptsetup reencrypt --batch-mode --resume-only --key-file="$image_key" --progress-frequency=30 "$dev" || return 1
          refresh || return 1
          state_set '.volume_key = "replaced"' || return 1
          say "the volume key is replaced"
        fi
        if [[ $(state volume_key) != replaced ]]; then
          if [[ $(jq '[.keyslots[] | select(.type != "reencrypt")] | length' <<< "$m") != 1 ]]; then
            say "not replacing the volume key: $dev has keys this service did not make (expected only the image key)"
            return 1
          fi
          on_mains || return 1
          say "replacing the volume key (online re-encryption of $dev; the PC stays usable)"
          # The image key is public, so its temporary keyslot gets the cheapest key derivation.
          cryptsetup reencrypt --batch-mode --key-file="$image_key" --pbkdf=pbkdf2 --pbkdf-force-iterations=1000 \
            --progress-frequency=30 "$dev" || return 1
          refresh || return 1
          state_set '.volume_key = "replaced"' || return 1
          say "the volume key is replaced"
        fi

        # 2. The TPM2, proven to unlock before anything depends on it.
        if [[ -z $(slots_of systemd-tpm2) ]]; then enrol_tpm || return 1; fi
        if ! tpm_unlocks; then
          if [[ -n $tpm_reenrolled ]]; then # once per boot: don't rewrite the header every minute
            say "the TPM2 still cannot unlock $dev; keeping the image key, trying again after the next boot"
            return 1
          fi
          tpm_reenrolled=1
          say "the TPM2 key does not unlock $dev in this boot's state; enrolling it again"
          systemd-cryptenroll --wipe-slot=tpm2 "$dev" || return 1
          refresh || return 1
          enrol_tpm || return 1
          if ! tpm_unlocks; then
            say "the TPM2 still cannot unlock $dev; keeping the image key"
            return 1
          fi
        fi

        # 3. A recovery key, escrowed with the panel. It is kept in memory across retries, so an
        #    outage costs no new keys; a fresh process starts over with a new one.
        if ! escrowed_slot > /dev/null; then
          if [[ -z $recovery_key ]]; then
            have_token || return 1
            discard_unescrowed || return 1
            new_recovery_key || return 1
          fi
          if ! recovery_key_opens; then
            say "the new recovery key does not open keyslot $recovery_slot; making another"
            recovery_key=
            discard_unescrowed
            return 1
          fi
          escrow || return 1
          state_set '.recovery_escrowed = true' || return 1
          recovery_key=
          say "the panel holds the recovery key (keyslot $recovery_slot)"
        fi

        # 4. Only now remove the image key: the TPM2 unlocks and the panel holds a working recovery key.
        if ! tpm_unlocks || ! escrowed_slot > /dev/null; then
          say "not removing the image key: the TPM2 or the escrowed recovery key is not in place"
          return 1
        fi
        cryptsetup luksRemoveKey --batch-mode --key-file="$image_key" "$dev" || return 1
        if image_key_opens; then
          say "the image key still opens $dev after removing it"
          return 1
        fi
        refresh || return 1
        done_summary
        return 0
      }

      while true; do
        if run_once; then exit 0; fi
        sleep 60
      done
    '';
  };
in {
  imports = [./agent.nix];

  options.codered.fleet.encryption = {
    enable = lib.mkEnableOption ''
      TPM2 disk encryption of the root file system. The PC must come from an image whose root is LUKS2
      opened by `imageKeyFile`; on first boot it gets its own volume key, a TPM2 unlock and an escrowed
      recovery key. Needs the fleet agent (its device token authenticates the escrow)
    '';
    device = mkOption {
      type = types.str;
      example = "/dev/disk/by-partlabel/disk-main-root";
      description = "The LUKS2 volume holding the root file system.";
    };
    mapperName = mkOption {
      type = types.str;
      default = "cryptroot";
      description = "Name of the opened volume, /dev/mapper/<name>.";
    };
    imageKeyFile = mkOption {
      type = types.path;
      example = lib.literalExpression "./image.key";
      description = ''
        The image's temporary LUKS key. It is not secret: it is in the image, the Nix store and the
        initrd. Every PC replaces its volume key and removes this key on first boot.
      '';
    };
    tpm2Pcrs = mkOption {
      type = types.nonEmptyListOf (types.ints.between 0 23);
      default = [7];
      description = ''
        TPM2 PCRs the disk key is sealed to. PCR 7 (Secure Boot policy) survives NixOS, kernel and
        bootloader updates; changing Secure Boot state or keys (or a dbx update) asks for the recovery key.
      '';
    };
    initrdLuksDevice = mkOption {
      type = types.attrsOf types.anything;
      readOnly = true;
      default = {
        inherit (cfg) device;
        allowDiscards = true;
        # TPM2 token first, then the recovery-key prompt, which repeats until a key is right.
        crypttabExtraOpts = ["tpm2-device=auto" "tries=0"];
      };
      defaultText = lib.literalExpression ''{ device = cfg.device; allowDiscards = true; crypttabExtraOpts = [ "tpm2-device=auto" "tries=0" ]; }'';
      description = ''
        The `boot.initrd.luks.devices.<mapperName>` entry this module sets. Read-only; for test VMs,
        whose framework empties `boot.initrd.luks.devices`, to re-apply it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = agent.enable;
        message = "codered.fleet.encryption needs codered.fleet.agent.enable: the recovery key is escrowed with the agent's device token.";
      }
    ];

    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.tpm2.enable = true;
    boot.initrd.luks.devices.${cfg.mapperName} = cfg.initrdLuksDevice;

    # First boot: the image key, tried before the crypttab unit (which then finds the volume open).
    # Once the key is removed this fails at once and the TPM2 token takes over.
    boot.initrd.systemd.contents.${initrdKey}.source = cfg.imageKeyFile;
    boot.initrd.systemd.services.fleet-image-key = {
      description = "Unlock ${cfg.mapperName} with the image key (first boot only)";
      unitConfig.DefaultDependencies = false;
      wantedBy = [cryptsetupUnit];
      before = [cryptsetupUnit "shutdown.target"];
      after = ["cryptsetup-pre.target" deviceUnit];
      bindsTo = [deviceUnit];
      conflicts = ["shutdown.target"];
      serviceConfig.Type = "oneshot";
      # headless + tries=1: one try with the key, never a prompt.
      script = ''
        if ${config.boot.initrd.systemd.package}/bin/systemd-cryptsetup attach ${quote cfg.mapperName} ${quote cfg.device} ${initrdKey} \
            ${quote (lib.concatStringsSep "," (activation ++ ["headless=true" "tries=1"]))} > /dev/null 2>&1; then
          echo "opened ${cfg.mapperName} with the image key: first-boot encryption setup is not finished yet"
        else
          echo "the image key does not open ${cfg.mapperName} (normal once set up); using the TPM2, or the recovery key"
        fi
      '';
    };

    systemd.services.fleet-encryption = {
      description = "CodeRed Fleet disk encryption: own volume key, TPM2, escrowed recovery key";
      wantedBy = ["multi-user.target"];
      after = ["tpm2.target"];
      # Never restarted by a switch: it may be in the middle of re-encrypting the disk.
      restartIfChanged = false;
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "exec";
        ExecStart = lib.getExe enrol;
        Restart = "on-failure";
        RestartSec = "60s";
        RuntimeDirectory = "fleet-encryption";
        RuntimeDirectoryMode = "0700";
        LimitCORE = 0;
        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
        # Re-encryption runs in the background of a PC in use.
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
      };
    };

    codered.fleet.agent.encryptedDevice = cfg.device;
  };
}

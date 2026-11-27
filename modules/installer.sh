# The unattended installer (README "Install PCs"). modules/installer.nix puts the settings in front of this
# file: panel_url panel_wait panel_wait_text group target_system disko_format disko_mount target_link
# nar_size_file store_paths token_file write_token esp_label fixed_hostname refusal_pause failure_pause
# net_mode cache_url cache_key
#
# Nobody touches the keyboard. Every check runs before any disk is touched: an install.json, a single
# internal disk to install on (or the one install.json names), no Fleet install already on the PC, and the
# panel answering `installing` with the enrol token. Until then every internal disk is read-only.

umask 022
work=/run/fleet-installer
probe=$work/probe
log=$work/install.log
mkdir -p "$probe"
chmod 700 "$work"

say() { printf 'fleet-installer: %s\n' "$*"; }
line() { printf '%s\n' '------------------------------------------------------------------------------'; }
banner() { # banner <title> <line>...: plain text on the screen, for a technician who may be watching
  local l
  echo
  line
  printf '  CodeRed Fleet installer: %s\n' "$1"
  shift
  echo
  for l in "$@"; do printf '  %s\n' "$l"; done
  line
  echo
}

finish() { # finish <reboot|poweroff> <seconds>
  trap - EXIT
  sleep "$2"
  systemctl "$1" --no-block
  exit 0
}

# Nothing has been changed on any disk.
refuse() {
  banner "NOT INSTALLING" "$@" "" "Nothing on this PC was changed. Restarting in $refusal_pause seconds."
  finish reboot "$refusal_pause"
}

# An unexpected error: before `installing` nothing was touched; after it, the disk may be half written.
phase=checks
# shellcheck disable=SC2329 # called through trap/with_fat
on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc == 0)); then return; fi
  if [[ $phase == install ]]; then failed "unexpected installer error (exit $rc)"; fi
  refuse "The installer stopped on an unexpected error (exit $rc)."
}
trap on_exit EXIT

# --- the PC's disks --------------------------------------------------------------------------------------

udevadm settle --timeout=120 || true

# The medium this installer runs from: the disk holding its store. Not in net mode: there the store was
# downloaded into RAM, and the only disks are the PC's own, among them the one whose EFI partition holds
# installer.efi and fleet/install.json (what the Windows migration script staged), which is the install target.
boot_disk=
if [[ $net_mode != true ]]; then
  store_part=$(findmnt -nro SOURCE /nix/.ro-store || true)
  if [[ -n $store_part ]]; then boot_disk=$(lsblk -ndo PKNAME "$store_part" 2>/dev/null || true); fi
fi

inventory=$(lsblk -J -b -d -o NAME,PATH,TYPE,RM,RO,TRAN,SIZE,MODEL,SERIAL)
field() { # field <disk path> <lsblk column>
  jq -r --arg p "$1" --arg f "$2" '.blockdevices[] | select(.path == $p) | .[$f] // "" | tostring | sub("\\s+$"; "")' <<< "$inventory"
}
describe() { # describe <disk path>: "nvme0n1 (512 GiB, Samsung SSD 980, serial S64...)"
  local model serial gib
  model=$(field "$1" model)
  serial=$(field "$1" serial)
  gib=$(($(field "$1" size) / 1073741824))
  printf '%s (%s GiB%s%s)' "${1#/dev/}" "$gib" "${model:+, $model}" "${serial:+, serial $serial}"
}

# Internal disks: never removable, never USB, never the boot medium, never a RAM, loop or optical device.
mapfile -t internal < <(jq -r --arg boot "$boot_disk" '
  def yes: . == true or . == "1" or . == 1;
  .blockdevices[]
  | select(.type == "disk" and .name != $boot)
  | select((.rm | yes) | not) | select((.ro | yes) | not)
  | select((.tran // "") != "usb")
  | select(.name | test("^(loop|ram|zram|sr|fd|nbd|md|dm-)|boot[0-9]+$|rpmb$") | not)
  | select((.size // 0) > 0)
  | .path' <<< "$inventory")

partitions_of() { lsblk -nrpo NAME "$1"; } # the disk itself, then its partitions

# Read-only until the one disk to install on is chosen and the panel has said yes.
for d in "${internal[@]}"; do
  while read -r dev; do blockdev --setro "$dev" 2>/dev/null || true; done < <(partitions_of "$d")
done

say "boot medium: ${boot_disk:-unknown}; internal disks: ${#internal[@]}"
for d in "${internal[@]}"; do say "  $(describe "$d")"; done

fat_parts() { # fat_parts <disk> [partlabel]: its FAT file systems
  lsblk -J -o PATH,FSTYPE,PARTLABEL "$1" | jq -r --arg l "${2:-}" '
    [.blockdevices[] | recurse(.children[]?)] | .[]
    | select(.fstype == "vfat" and ($l == "" or .partlabel == $l)) | .path'
}
with_fat() { # with_fat <partition> <command...>: run it with the FAT mounted read-only at $probe
  mount -t vfat -o ro,nodev,nosuid,noexec "$1" "$probe" 2> /dev/null || return 1
  local rc=0
  "${@:2}" || rc=$?
  umount "$probe" 2> /dev/null || umount -l "$probe"
  return "$rc"
}

# --- fleet/install.json -----------------------------------------------------------------------------------

txt_hint=
# shellcheck disable=SC2329 # called through trap/with_fat
copy_config() {
  local f
  f=$(find "$probe" -mindepth 2 -maxdepth 2 -type f -ipath "$probe/fleet/install.json" -print -quit 2> /dev/null || true)
  if [[ -z $f ]]; then
    if [[ -n $(find "$probe" -mindepth 2 -maxdepth 2 -type f -ipath "$probe/fleet/install.json.txt" -print -quit 2> /dev/null || true) ]]; then
      txt_hint=1
    fi
    return 1
  fi
  head -c 65536 "$f" > "$work/install.json"
}

# The stick first (the technician's), then any other disk: the Windows migration script stages it on the
# PC's own EFI system partition.
search=()
if [[ -n $boot_disk ]]; then search+=("/dev/$boot_disk"); fi
mapfile -t -O "${#search[@]}" search < <(jq -r --arg boot "$boot_disk" '.blockdevices[] | select(.type == "disk" and .name != $boot) | .path' <<< "$inventory")
config_from=
for d in "${search[@]}"; do
  while read -r p; do
    [[ -n $p ]] || continue
    if with_fat "$p" copy_config; then
      config_from=$p
      break 2
    fi
  done < <(fat_parts "$d")
done

if [[ -z $config_from ]]; then
  if [[ -n $txt_hint ]]; then
    refuse "Found fleet/install.json.txt, but no fleet/install.json." \
      "Rename the file to install.json (Windows hides the .txt ending)."
  fi
  refuse "No fleet/install.json was found, on the USB stick or on this PC's own disks." \
    "Put one in the \"fleet\" folder of the stick: see fleet/README.txt on the stick."
fi
say "using fleet/install.json from $config_from"

json=$(sed '1s/^\xef\xbb\xbf//' "$work/install.json") # Notepad may add a byte-order mark
if ! jq -e 'type == "object"' > /dev/null 2>&1 <<< "$json"; then
  refuse "fleet/install.json (on $config_from) is not valid JSON." \
    'It should look like: {"enroll_token": "...", "hostname": "office-07"}'
fi
str() { jq -r --arg k "$1" 'if (.[$k] | type) == "string" then .[$k] else "" end' <<< "$json"; }
token=$(str enroll_token)
token=${token#"${token%%[![:space:]]*}"}
token=${token%"${token##*[![:space:]]}"}
if [[ -z $token ]]; then
  refuse "fleet/install.json (on $config_from) has no \"enroll_token\"." "Copy it from the panel: Settings > Enrol token."
fi
if [[ ! $token =~ ^[[:graph:]]+$ ]]; then
  refuse "The enroll_token in fleet/install.json contains spaces or control characters."
fi
new_hostname=$(str hostname)
new_hostname=${new_hostname,,}
if [[ -n $new_hostname && ! $new_hostname =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  refuse "The hostname \"$new_hostname\" in fleet/install.json is not a valid PC name." \
    "Use letters, digits and hyphens (not at the start or end), at most 63 characters."
fi
want_disk=$(str disk)
reinstall=false
if jq -e '.reinstall == true' > /dev/null <<< "$json"; then reinstall=true; fi

# --- the panel ------------------------------------------------------------------------------------------

serial=$(cat /sys/class/dmi/id/product_serial 2> /dev/null || true) # as the agent reports it
serial=${serial:-unknown}

post_status() { # post_status <status> <detail>: prints the HTTP code ("000": no answer)
  jq -n --arg serial "$serial" --arg status "$1" --arg detail "${2:0:255}" '{$serial, $status, $detail}' |
    curl --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 5 --max-time 30 \
      -H 'Content-Type: application/json' -H @<(printf 'Authorization: Bearer %s\n' "$token") \
      --data-binary @- "$panel_url/api/v1/migration-status" 2> /dev/null || true
}

panel_code=
# tell_panel <status> <detail>, retrying for panel_wait seconds while the panel does not answer.
# 0: taken (2xx, or 404: the panel never saw this PC's Windows inventory); 1: the enrol token was refused;
# 2: refused otherwise; 3: no answer in time.
tell_panel() {
  local deadline shown=
  deadline=$(($(date +%s) + panel_wait))
  while :; do
    panel_code=$(post_status "$1" "$2")
    case $panel_code in
      2?? | 404) return 0 ;;
      401 | 403) return 1 ;;
      4??) return 2 ;;
    esac
    if (($(date +%s) >= deadline)); then return 3; fi
    if [[ -z $shown ]]; then
      say "waiting for the panel at $panel_url (up to $panel_wait_text)"
      shown=1
    fi
    sleep 5
  done
}

# A refusal the panel can act on (which disk?): tell it, then refuse.
refuse_and_report() { # refuse_and_report <detail for the panel> <lines for the screen...>
  local rc=0
  tell_panel failed "$1" || rc=$?
  shift
  case $rc in
    0) refuse "$@" "" "The panel has been told why." ;;
    1) refuse "$@" "" "The panel refused the enrol token in install.json (HTTP $panel_code), so it was not told." ;;
    2) refuse "$@" "" "The panel refused the report (HTTP $panel_code)." ;;
    *) refuse "$@" "" "The panel at $panel_url could not be reached to tell it." ;;
  esac
}

# --- which disk -----------------------------------------------------------------------------------------

# shellcheck disable=SC2329 # called through trap/with_fat
has_fleet_entries() { [[ -n $(find "$probe/loader/entries" -maxdepth 1 -type f -iname 'nixos-*.conf' -print -quit 2> /dev/null || true) ]]; }
fleet_esp() { # fleet_esp <disk>: prints its EFI partition if the disk holds a Fleet install
  local p
  while read -r p; do
    [[ -n $p ]] || continue
    if with_fat "$p" has_fleet_entries; then
      echo "$p"
      return 0
    fi
  done < <(fat_parts "$1" "$esp_label")
  return 1
}

boot_entry_for() { # boot_entry_for <EFI partition>: the firmware's Boot#### entry for it, made if missing
  local part=$1 uuid entry disk num
  uuid=$(lsblk -ndo PARTUUID "$part")
  [[ -n $uuid ]] || return 1
  entry=$(efibootmgr -v 2> /dev/null | grep -iF "$uuid" | sed -nE 's/^Boot([0-9A-Fa-f]{4}).*/\1/p' | head -n1 || true)
  if [[ -z $entry ]]; then
    disk=/dev/$(lsblk -ndo PKNAME "$part")
    num=$(< "/sys/class/block/${part##*/}/partition")
    efibootmgr --create --disk "$disk" --part "$num" --label "CodeRed Fleet" \
      --loader '\EFI\systemd\systemd-bootx64.efi' > /dev/null || return 1
    entry=$(efibootmgr -v 2> /dev/null | grep -iF "$uuid" | sed -nE 's/^Boot([0-9A-Fa-f]{4}).*/\1/p' | head -n1 || true)
  fi
  [[ -n $entry ]] || return 1
  echo "$entry"
}

if ! $reinstall; then # "reinstall": true in install.json is the deliberate override
  for d in "${internal[@]}"; do
    if esp=$(fleet_esp "$d"); then
      # So the restart comes up in Fleet even if the stick stays in and the firmware prefers USB.
      if entry=$(boot_entry_for "$esp"); then efibootmgr --bootnext "$entry" > /dev/null 2>&1 || true; fi
      refuse "This PC already runs CodeRed Fleet ($(describe "$d")), so it is not reinstalled." \
        "To reinstall it on purpose, add \"reinstall\": true to fleet/install.json."
    fi
  done
fi

internal_list() {
  local d sep=
  for d in "${internal[@]}"; do
    printf '%s%s' "$sep" "$(describe "$d")"
    sep='; '
  done
}

target=
if [[ -n $want_disk ]]; then
  real=
  if [[ $want_disk == /dev/* ]]; then real=$(readlink -f "$want_disk" 2> /dev/null || true); fi
  for d in "${internal[@]}"; do
    if [[ $d == "$real" || ${d#/dev/} == "$want_disk" || $(field "$d" serial) == "$want_disk" ]]; then
      target=$d
      break
    fi
  done
  if [[ -z $target ]]; then
    refuse_and_report "install.json names disk \"$want_disk\", which is not an internal disk of this PC (internal disks: $(internal_list))" \
      "fleet/install.json names disk \"$want_disk\", which is not an internal disk of this PC." \
      "Internal disks: $(internal_list)"
  fi
else
  case ${#internal[@]} in
    0) refuse_and_report "no internal disk to install on" "This PC has no internal disk to install on." ;;
    1) target=${internal[0]} ;;
    *)
      refuse_and_report "${#internal[@]} internal disks and install.json names none; set \"disk\" to one of: $(internal_list)" \
        "This PC has ${#internal[@]} internal disks and fleet/install.json does not say which one to use." \
        "Add \"disk\" to install.json, one of: $(internal_list)"
      ;;
  esac
fi

size=$(field "$target" size)
need=$(($(< "$nar_size_file") * 11 / 10 + (2 << 30))) # the system, file system overhead, the EFI partition
if ((size < need)); then
  refuse_and_report "disk $(describe "$target") is too small for $group: it needs $((need >> 30)) GiB" \
    "The disk $(describe "$target") is too small for $group: it needs at least $((need >> 30)) GiB."
fi

# --- net mode: the cache must have the group's system, signed by the group's key ---------------------------

if [[ $net_mode == true ]]; then
  say "checking that the binary cache at $cache_url has $group, signed by the group's key"
  cache_ok=
  for _ in 1 2 3; do
    # Every path of the system's closure must be there and carry a signature from cache_key.
    if cache_out=$(nix --extra-experimental-features nix-command store verify --no-contents --sigs-needed 1 \
      --store "$cache_url" --trusted-public-keys "$cache_key" --connect-timeout 15 --recursive "$target_system" 2>&1 > /dev/null); then
      cache_ok=1
      break
    fi
    cache_errs=$(grep -v '^checking ' <<< "$cache_out" || true)
    printf '%s\n' "$cache_errs" >> "$log"
    [[ $cache_out == *untrusted* ]] && break # it answered: no point in asking again
    sleep 5
  done
  if [[ -z $cache_ok ]]; then
    cache_why=${cache_errs%%$'\n'*}
    cache_why=${cache_why:0:160}
    if [[ $cache_out == *untrusted* ]]; then
      cache_why="its paths are not signed by the key in this installer ($cache_why)"
    fi
    refuse_and_report "the binary cache at $cache_url cannot supply $group: ${cache_why:-no answer}" \
      "The binary cache at $cache_url cannot supply $group," \
      "or it is not signed by the key this installer trusts." \
      "${cache_why:-No answer.}"
  fi
fi

# --- the panel says yes: install -------------------------------------------------------------------------

target_desc=$(describe "$target")
rc=0
tell_panel installing "installing $group on $target_desc" || rc=$?
case $rc in
  0) ;;
  1) refuse "The panel at $panel_url refused the enrol token in fleet/install.json (HTTP $panel_code)." \
    "Check the token: panel > Settings > Enrol token." ;;
  2) refuse "The panel at $panel_url refused to install this PC (HTTP $panel_code)." ;;
  *) refuse "Could not reach the panel at $panel_url within $panel_wait_text." \
    "Check the network cable, and that this network can reach the panel." ;;
esac

phase=install
banner "INSTALLING $group" "on $target_desc" "Everything on this disk is being replaced. Do not turn the PC off."

close_target() { # unmount and lock everything on the target disk
  umount -R /mnt 2> /dev/null || true
  local dm
  while read -r dm; do cryptsetup close "$dm" 2> /dev/null || true; done < <(lsblk -nrpo NAME,TYPE "$target" | awk '$2 == "crypt" {print $1}')
}

failed() { # failed <what>: after `installing`, the disk may be half written
  say "install failed: $1"
  if [[ -s $log ]]; then
    say "last output:"
    tail -n 15 "$log"
  fi
  close_target
  sync
  local told="The panel could not be told."
  if tell_panel failed "$1"; then told="The panel has been told."; fi
  banner "INSTALL FAILED" "$1" "$told" "" \
    "The disk $target_desc was being replaced and may not start any more." \
    "Powering off in $failure_pause seconds."
  finish poweroff "$failure_pause"
}

detail() { # detail <command...>: its output goes to the journal and the install log, not the screen
  "$@" 2>&1 | tee -a "$log" | systemd-cat -t fleet-install
}

say "preparing $target"
for dev in $(partitions_of "$target"); do blockdev --setrw "$dev" || failed "could not make $target writable"; done
# Old file systems, encryption and RAID signatures, then the partition table itself.
for dev in $(partitions_of "$target" | tail -n +2); do
  detail wipefs --all --force "$dev" || failed "could not wipe $dev"
done
detail wipefs --all --force "$target" || failed "could not wipe $target"
detail sgdisk --zap-all "$target" || failed "could not clear the partition table of $target"
blockdev --rereadpt "$target" 2> /dev/null || true
udevadm settle --timeout=60 || true

say "partitioning, encrypting and formatting"
ln -sfn "$target" "$target_link" # the group's own disko layout, aimed at this disk
detail "$disko_format" || failed "partitioning or formatting $target failed"
detail "$disko_mount" || failed "mounting the new file systems failed"

if [[ $net_mode == true ]]; then
  say "downloading $group from the binary cache (this takes a while)"
  # Only the cache, and only paths signed by its key.
  substituter_opts=(--option substituters "$cache_url" --option trusted-public-keys "$cache_key" --option require-sigs true
    --option connect-timeout 30 --option fallback false)
else
  say "copying $group from the stick (this takes a few minutes)"
  substituter_opts=(--option substituters "")
fi
copy_system() { # nixos-install, with its progress on the screen every 10%
  local total
  total=$(wc -l < "$store_paths")
  nixos-install --system "$target_system" --root /mnt --no-root-passwd --no-channel-copy "${substituter_opts[@]}" 2>&1 |
    tee -a "$log" >(systemd-cat -t fleet-install) |
    awk -v total="$total" '/^copying path/ {
      n++; p = int(n * 100 / total) - int(n * 100 / total) % 10
      if (p > shown) { shown = p; printf "fleet-installer: copied %d%%\n", p; fflush() }
    }'
}
copy_system || failed "copying the system or installing the boot loader failed"

if [[ -n $new_hostname ]]; then
  if [[ -n $fixed_hostname ]]; then
    say "note: $group sets its own hostname ($fixed_hostname); \"$new_hostname\" from install.json is not used"
  fi
  printf '%s\n' "$new_hostname" > /mnt/etc/hostname || failed "could not write /etc/hostname"
fi
if $write_token; then
  dir=/mnt$(dirname "$token_file")
  if [[ ! -d $dir ]]; then install -d -m 0700 "$dir" || failed "could not create $dir"; fi
  (umask 077 && printf '%s\n' "$token" > "/mnt$token_file") || failed "could not write the enrol token"
  chmod 0600 "/mnt$token_file"
else
  say "note: $group reads its enrol token from $token_file at run time; it is not written to the disk"
fi

say "setting the firmware to start the installed system"
esp=$(findmnt -nro SOURCE /mnt/boot || true)
[[ -n $esp ]] || failed "the new EFI system partition is not mounted"
esp=$(readlink -f "$esp")
entry=$(boot_entry_for "$esp") || failed "could not create a firmware boot entry for $esp"
order=$(efibootmgr | sed -n 's/^BootOrder: //p')
order=$(printf '%s' "$entry,$order" | tr ',' '\n' | awk 'NF && !seen[toupper($0)]++' | paste -sd, -)
detail efibootmgr --bootorder "$order" || failed "could not set the firmware boot order"
detail efibootmgr --bootnext "$entry" || failed "could not set the firmware's next boot"

close_target
sync
banner "INSTALLED $group" "on $target_desc${new_hostname:+, as $new_hostname}" "" \
  "Restarting into the new system in 10 seconds; the USB stick can come out." \
  "On first start it encrypts its disk with the TPM and enrols with the panel by itself."
finish reboot 10

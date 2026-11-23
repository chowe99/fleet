#!/usr/bin/env bash
# LOCKED acceptance test: do not edit, weaken, skip or delete.
# End to end against the live panel (fleet.codered.lol, Demo School): a disk-installed demo PC
# (UEFI + systemd-boot, its own /nix/store, built from .#demo-image) enrols with a token passed in
# over QEMU fw_cfg, is moved to the pilot ring, the ring is pointed at TARGET_REV, the PC stages
# that version without switching live, and after a reboot it reports running it.
# Usage: tests/e2e-update.sh <TARGET_REV>   (a commit on github:chowe99/fleet, not the image's own)
set -euo pipefail
TARGET=${1:?usage: $0 <target-rev>}
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
ORACLE=root@100.64.0.4
HOST=demo-lab-01
ORG="(select id from fleet_organisation where name='Demo School')"
trap 'kill "$(cat "$WORK/qemu.pid" 2>/dev/null)" 2>/dev/null || true' EXIT

sql() { ssh -o BatchMode=yes "$ORACLE" "runuser -u postgres -- psql -d fleet_panel -tAc \"$1\""; }
wait_for() { # wait_for <seconds> <description> <shell expression>
  for ((i = 0; i < $1; i += 10)); do
    if eval "$3"; then echo "ok: $2"; return; fi
    sleep 10
  done
  echo "FAIL: timed out waiting for $2"
  exit 1
}

nix build "$REPO#demo-image" -o "$WORK/image"
cp --sparse=always "$WORK/image/main.raw" "$WORK/disk.raw"
chmod u+w "$WORK/disk.raw"
OVMF=$(nix build --no-link --print-out-paths nixpkgs#OVMF.fd)
QEMU=$(nix build --no-link --print-out-paths nixpkgs#qemu_kvm)/bin/qemu-system-x86_64
cp "$OVMF/FV/OVMF_VARS.fd" "$WORK/vars.fd"
chmod u+w "$WORK/vars.fd"
sql "select enroll_token from fleet_organisation where id=$ORG" | tr -d '\n' >"$WORK/token"

boot() {
  env -u LD_LIBRARY_PATH "$QEMU" -enable-kvm -m 6144 -smp 4 -display none \
    -daemonize -pidfile "$WORK/qemu.pid" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF/FV/OVMF_CODE.fd" \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -drive file="$WORK/disk.raw",format=raw,if=virtio \
    -fw_cfg name=opt/codered/enroll-token,file="$WORK/token" \
    -nic user,model=virtio-net-pci \
    -qmp unix:"$WORK/qmp.sock",server=on,wait=off
}
powerdown() { # graceful ACPI shutdown, then wait for QEMU to exit
  python3 -I - "$WORK/qmp.sock" <<'EOF'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rw")
f.readline()
for cmd in ("qmp_capabilities", "system_powerdown"):
    f.write(json.dumps({"execute": cmd}) + "\n"); f.flush(); f.readline()
EOF
  wait_for 300 "the PC to shut down" "! kill -0 \"\$(cat '$WORK/qemu.pid')\" 2>/dev/null"
}

sql "delete from fleet_device where hostname='$HOST' and organisation_id=$ORG" >/dev/null
boot
wait_for 900 "enrolment" "[ -n \"\$(sql \"select id from fleet_device where hostname='$HOST' and last_seen is not null\")\" ]"
DEV=$(sql "select id from fleet_device where hostname='$HOST'")
BEFORE=$(sql "select current_rev from fleet_device where id=$DEV")
echo "image runs: $BEFORE"
[ "$BEFORE" != "$TARGET" ] || { echo "FAIL: the image already runs $TARGET"; exit 1; }

# What an admin does in the panel: point the pilot ring at TARGET and put this PC in it.
sql "update fleet_ring set target_rev='$TARGET' where name='pilot' and organisation_id=$ORG" >/dev/null
sql "update fleet_device set ring_id=(select id from fleet_ring where name='pilot' and organisation_id=$ORG) where id=$DEV" >/dev/null

wait_for 2400 "the PC to stage $TARGET" "[ \"\$(sql \"select (last_update->>'rev') || ' ' || (last_update->>'ok') from fleet_device where id=$DEV\")\" = '$TARGET true' ]"
NOW=$(sql "select current_rev from fleet_device where id=$DEV")
[ "$NOW" = "$BEFORE" ] || { echo "FAIL: boot mode switched the running system ($NOW)"; exit 1; }

powerdown
boot
wait_for 900 "the PC to report $TARGET after reboot" "[ \"\$(sql \"select current_rev from fleet_device where id=$DEV\")\" = '$TARGET' ]"

sql "delete from fleet_device where id=$DEV" >/dev/null
sql "update fleet_ring set target_rev=NULL where name='pilot' and organisation_id=$ORG" >/dev/null
echo "PASS: enrolled, staged $TARGET without switching, and runs it after reboot"

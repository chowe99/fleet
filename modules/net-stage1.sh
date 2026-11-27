# Stage 1 of the network installer (modules/installer.nix, run by NixOS' stage 1 after udev has loaded the
# network drivers, before it mounts anything). installer.efi carries only this and the drivers: it fetches
# stage 2, the installer system, from net.url into RAM, checks it against the hash built into installer.efi,
# and lets NixOS' stage 1 mount it as /nix/store and carry on into it.
#
# Nothing here touches a disk (no storage driver is even loaded), and a failure never sets a new one-time
# boot: it shows why, waits, and restarts, so a PC the Windows migration script booted once comes back as
# Windows. @url@ is replaced with net.url.
fleet_url=@url@
fleet_pause=30

fleet_say() {
  echo "fleet-installer: $*"
  echo "<3>fleet-installer: $*" > /dev/kmsg 2> /dev/null || true # also on the serial console
}

fleet_refuse() { # fleet_refuse <line>...: nothing was changed; restart
  echo
  echo "------------------------------------------------------------------------------"
  echo "  CodeRed Fleet installer: NOT INSTALLING"
  echo
  for l in "$@"; do
    echo "  $l"
    echo "<3>fleet-installer: $l" > /dev/kmsg 2> /dev/null || true
  done
  echo
  echo "  Nothing on this PC was changed. Restarting in $fleet_pause seconds."
  echo "------------------------------------------------------------------------------"
  echo
  sleep "$fleet_pause"
  reboot -f
  sleep 60
}

cat > /udhcpc.script << 'FLEET_EOF'
#!/bin/sh
if [ "$1" = bound ] || [ "$1" = renew ]; then
  ip address add "$ip/$mask" dev "$interface" 2> /dev/null
  [ -n "$mtu" ] && ip link set mtu "$mtu" dev "$interface"
  if [ -n "$router" ]; then
    ip route add "${router%% *}" dev "$interface" 2> /dev/null
    ip route add default via "${router%% *}" dev "$interface" 2> /dev/null
  fi
  rm -f /etc/resolv.conf
  for server in $dns; do echo "nameserver $server" >> /etc/resolv.conf; done
fi
exit 0
FLEET_EOF
chmod +x /udhcpc.script

fleet_uptime() { cut -d. -f1 /proc/uptime; }

# Wired network cards only: the ones with a device behind them (not wireless, bridges, loopback).
fleet_nics() {
  for i in /sys/class/net/*; do
    n=${i##*/}
    [ "$n" = lo ] && continue
    [ -e "$i/device" ] || continue
    [ -e "$i/wireless" ] && continue
    [ -e "$i/phy80211" ] && continue
    echo "$n"
  done
}

# Brings up the first card that gets an address by DHCP; waits up to 90 seconds (link negotiation is slow).
fleet_dhcp() {
  deadline=$(($(fleet_uptime) + 90))
  while [ "$(fleet_uptime)" -lt "$deadline" ]; do
    for n in $(fleet_nics); do
      ip link set dev "$n" up 2> /dev/null || continue
      if udhcpc --quit --now -i "$n" -t 3 -T 3 -s /udhcpc.script > /dev/null 2>&1; then
        fleet_nic=$n
        return 0
      fi
    done
    sleep 2
  done
  return 1
}

fleet_say "starting the network"
fleet_nic=
fleet_dhcp || fleet_refuse "No network: no wired network card got an address by DHCP." \
  "Check the network cable. Wi-Fi is not used by this installer."
fleet_say "network up on $fleet_nic"

fleet_sha=$(cat /fleet/stage2.sha256)
fleet_file=stage2-$fleet_sha.squashfs
fleet_say "downloading $fleet_url/$fleet_file"
fleet_rc=0
fleet_err=$(CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt curl --fail --silent --show-error --location \
  --proto '=http,https' --proto-redir '=http,https' --connect-timeout 15 --max-time 3600 --retry 2 \
  --output /nix-store.squashfs "$fleet_url/$fleet_file" 2>&1) || fleet_rc=$?
if [ "$fleet_rc" != 0 ]; then
  rm -f /nix-store.squashfs
  fleet_refuse "Could not download the installer's files from $fleet_url." \
    "$fleet_file: $(echo "$fleet_err" | tail -n 1)" \
    "(curl exit $fleet_rc)"
fi

fleet_say "checking the download"
fleet_got=$(sha256sum /nix-store.squashfs | cut -d' ' -f1)
if [ "$fleet_got" != "$fleet_sha" ]; then
  rm -f /nix-store.squashfs
  fleet_refuse "The installer's files from $fleet_url do not match what this installer expects." \
    "$fleet_file has the wrong checksum, so it was not used."
fi
fleet_say "installer files verified; starting the installer system"

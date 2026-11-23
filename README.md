# CodeRed Fleet

Managed NixOS desktops for schools and businesses moving off Windows: a
Windows-style KDE Plasma 6 desktop, LibreOffice, and every PC managed as code
from one flake.

## Layout

| Path | What |
|------|------|
| `flake.nix` | `lib.mkUsers`, `lib.mkFleet`, modules, template, `school-vm`, `demo-lab` + `demo-image`, checks |
| `modules/base.nix` | installable image: UEFI systemd-boot, disko layout, generic hardware |
| `modules/desktop.nix` | `nixosModules.desktop`: Plasma 6 with a bottom taskbar, start menu and pinned apps (`desktop-layout.js`), LibreOffice, en_AU |
| `modules/school.nix` | `nixosModules.school`: desktop plus lockdown (no sudo/nix for non-admins, USB storage blocked, Firefox policies, KDE Kiosk, screen lock, no app store) |
| `modules/agent.nix` | `nixosModules.agent` (`codered.fleet.agent`): enrols with the panel, reports, applies target revisions |
| `examples/school/` | `templates.school`: what a customer's IT department gets |
| `tests/` | acceptance tests (locked) |

## Run the checks

```sh
nix build .#checks.x86_64-linux.fleet
nix build .#checks.x86_64-linux.school -L -o result-school   # needs KVM; screenshot in result-school/
```

## Run the school image as a VM

```sh
nix run .#school-vm
```

Log in as `student1`, `teacher1` or `itadmin` (the only admin) with the demo
password `demo`. That password exists only in the demo configurations
(`school-vm`, `demo-lab`).

## See an update roll out

`.#demo-image` is the school image installed on a disk (group `demo-lab`, PC
`demo-lab-01`): UEFI, systemd-boot and its own `/nix/store`, so it can stage a
new version and boot into it. It reports to https://fleet.codered.lol
(organisation "Demo School") every 2 minutes.

1. Build the image and boot it. The enrol token (panel > Settings) goes in over
   QEMU fw_cfg, so it is never in the image or the store:

   ```sh
   D=$(mktemp -d)
   nix build .#demo-image -o $D/image
   cp --sparse=always $D/image/main.raw $D/disk.raw && chmod u+w $D/disk.raw   # 24G, sparse
   OVMF=$(nix build --no-link --print-out-paths nixpkgs#OVMF.fd)
   install -m600 $OVMF/FV/OVMF_VARS.fd $D/vars.fd
   printf %s '<enrol token>' > $D/token
   env -u LD_LIBRARY_PATH $(nix build --no-link --print-out-paths nixpkgs#qemu_kvm)/bin/qemu-system-x86_64 \
     -enable-kvm -m 6144 -smp 4 \
     -drive if=pflash,format=raw,readonly=on,file=$OVMF/FV/OVMF_CODE.fd \
     -drive if=pflash,format=raw,file=$D/vars.fd \
     -drive file=$D/disk.raw,format=raw,if=virtio \
     -fw_cfg name=opt/codered/enroll-token,file=$D/token \
     -nic user,model=virtio-net-pci
   ```

2. **Devices:** `demo-lab-01` appears in the `everyone` ring, running the commit
   the image was built from. Open it and move it to `pilot`.
3. **Rings:** set `pilot`'s target to a newer commit of `github:chowe99/fleet`
   (one that bumps `/etc/fleet-release`). The PC builds that commit and stages
   it: its last update shows the commit as ok, but it keeps running the old one,
   so nothing changes mid-lesson.
4. Restart the PC (start menu or login screen). It comes back on the new commit,
   and `cat /etc/fleet-release` shows the bump.
5. **Rings:** promote `pilot` to send the same version to `everyone`.

`tests/e2e-update.sh <commit>` runs steps 1 to 4 headless against the panel.

## Settings (fleet-settings.json)

Per-customer settings are plain data, so the panel can edit them without touching
Nix. A customer's config repo carries `fleet-settings.json`, and the template's
`flake.nix` passes it to `mkFleet { settings = ...; }`. Every key is optional:

```json
{ "homepage": "https://...",
  "usbStorage": true,
  "timezone": "Australia/Sydney",
  "wifi": [{ "ssid": "SchoolNet", "psk": "..." }],
  "printers": [{ "name": "Library", "uri": "ipp://10.0.0.5/ipp/print" }],
  "generate": { "student": 30 } }
```

| Key | Becomes |
|-----|---------|
| `homepage` | Firefox homepage for every group (`programs.firefox.policies.Homepage.URL`) |
| `usbStorage` | `codered.fleet.school.allowUsbStorage` |
| `timezone` | `time.timeZone` (default `Australia/Perth`) |
| `wifi` | NetworkManager `ensureProfiles`: WPA-PSK, autoconnect |
| `printers` | `hardware.printers.ensurePrinters` (driverless, model `everywhere`), CUPS on |
| `generate` | merged into `mkUsers`' `generate` (wins over the `users.generate` argument) |

Settings apply to every group at normal priority, so a group's own `modules` can
override them with `lib.mkForce`. An unknown key, a wrong type, or a printer name
that is not CUPS-safe (letters, digits, `_`, `-`) fails evaluation with a clear message.

**Security: Wi-Fi passwords are not secret.** A `psk` is written into the NixOS
configuration, so it lands in the world-readable Nix store (and the repo) on every
PC. Treat it as visible to any local user. Moving PSKs to a runtime-read secret file
is future work.

## Design

- **One image per group, not per PC.** `mkFleet { groups = { lab = { profile = "school"; }; }; ... }`
  returns one `nixosSystem` per group, so 1,000 lab PCs share one build. The
  image has no hostname: a PC's name comes from the installer (`/etc/hostname`)
  or DHCP, and its identity from enrolment with the panel.
- **Users from a loop plus folders.** `mkUsers { generate.student = 500; dir = ./users; }`
  makes `student1`..`student500`, then merges each `users/<name>/default.nix`
  over them, so IT can override a student or add staff (`extraGroups = ["wheel"]`
  for admins). Homes are created at first login (PAM), not on every PC.
- **System-wide desktop.** The layout is a Plasma global theme set as the default
  in `/etc/xdg/kdeglobals`, so it applies to generated users without home-manager.
- **Updates on the panel's schedule.** The agent runs at boot and every 15
  minutes, and applies `target_rev` with `nixos-rebuild boot` by default, so a PC
  changes at its next restart, never mid-lesson.
- **No passwords in the library.** In production, people sign in through the
  school's directory: Entra ID via Himmelblau, or AD/LDAP via SSSD.

## Out of scope (for now)

- Directory sign-in (Himmelblau / SSSD)
- Web filtering
- Secure Boot (Lanzaboote)
- Installer and netboot images

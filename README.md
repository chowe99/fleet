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

## Remote actions

An organisation admin can press "Reboot when idle" or "Update now" for a PC in the panel. The panel
hands the action to the PC in its check-in reply; the agent does it at that check-in:

- It reboots only when no logind session has `Class=user`; otherwise it reports `deferred` and
  retries at each check-in, unless the admin ticked "force".
- "Update now" stages the ring's target version (as the normal update does), then reboots under the same rule.
- The `done` result of a reboot is saved to `/var/lib/fleet-agent/pending-results.json` first and sent
  at the first check-in after boot. Unknown action types are reported `failed`.

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

## When an update goes wrong

A new version is a trial. After an update is staged, the PC starts it at the next restart, up to
three times (`codered.fleet.fallback.tries`). A start counts as good only when the PC finishes
booting and the units it cannot do without are running (by default the login screen and the fleet
agent; `requiredUnits`). Then the version is kept and the PC runs it from then on. The module is on
by default for every `mkFleet` group (`codered.fleet.fallback.enable`).

If the new version fails, nobody needs to go to the PC:

- A required unit failed: the PC restarts itself within seconds.
- The PC is up but unhealthy, or the start never finishes (a service that hangs): it restarts itself
  once `bootTimeout` (default 10 minutes from power-on) has passed without a good boot.
- After the tries are used up, the boot menu skips that version and the PC starts the last good one.
  It then marks the update as failed: the panel shows the PC's last update as not ok, the system is set
  back to the version that works, and the agent does not stage that same revision again. To roll out a
  fix, publish a new revision. (To retry the very same revision, delete its line from
  `/var/lib/fleet-fallback/failed-revs` on the PC.)

The last good version is never restarted by this: only a version still on trial can be abandoned, and
once a version has booted good it stays good, whatever happens later.

What still needs a visit:

- A PC that hangs before the boot loader runs (firmware, a dead disk, a corrupt EFI partition).
- A hang in the kernel or early boot with no hardware watchdog: the PC waits until someone presses
  the power button. Where the PC has a hardware watchdog, systemd arms it once it is running, so a
  frozen system restarts. A kernel panic restarts after 10 seconds.
- A failure of the last good version itself (nothing older to go back to), or a trial whose boot
  loader entry is damaged.
- Problems the check cannot see: a version that boots and passes the check but is broken in some other
  way is kept. Put what matters in `requiredUnits`.
- It needs UEFI with systemd-boot (the fleet images use it). Without UEFI boot counting is off.

## Config hosted by the panel

The panel hosts each customer's config repo and serves any commit as a tarball at
`https://<panel>/api/v1/config/<sha>.tar.gz`, behind HTTP basic auth (user `device`, password = the
PC's device token). Set `codered.fleet.agent.flakeUrlTemplate = "https://<panel>/api/v1/config/{rev}.tar.gz"`
and an update runs `nixos-rebuild <applyMode> --flake "<template with {rev} replaced>#<group>"`. The
template takes precedence over `flake`; with it unset the old `<flake>?rev=<rev>#<group>` path is used.
The agent rejects target revisions that are not 6-40 lowercase hex characters.

After enrolment (and on every run, so token changes follow) the agent writes
`/var/lib/fleet-agent/netrc` (`machine <panel host> login device password <token>`, root-only, mode
0600) and the module sets `nix.settings.netrc-file` to it, so nix authenticates to the panel host only.
The token is as protected as the device token already is: root-only on disk, never printed or put on
a command line.

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

## Active Directory sign-in

`self.nixosModules.directory` (off by default) joins a PC to an on-premises AD domain so staff and
students sign in with their existing username and password. It uses SSSD (AD provider), adcli
and Kerberos. Add it to a group's `modules`:

```nix
imports = [fleet.nixosModules.directory];
codered.fleet.directory = {
  enable = true;
  domain = "school.example.edu";
  joinUser = "svc-join";
  joinPasswordFile = "/run/agenix/join-password"; # a runtime secret, never a store path
  adminGroups = ["Fleet Admins"];                 # AD groups that get sudo
  ntpServers = ["dc1.school.example.edu"];
};
```

What the PC does: `fleet-directory-join.service` joins at boot, retries every 30 s until a domain
controller answers, never blocks boot, and only rejoins when the keytab is missing or stale. Users sign
in with the short name (`alice`), get a home folder on first sign-in, and can sign in again with cached
credentials when no domain controller is reachable (after one online sign-in). The VM test
`checks.x86_64-linux.directory` runs this against a real Samba AD domain controller.

What an IT admin must provide:

- **DNS** pointing at the domain controllers (DHCP option or `networking.nameservers`); the PC finds the DCs from SRV records.
- **A join account** with only the delegated right to create computer objects in the target OU (`computerOu`), not a Domain Admin.
- **The join password as a secret** file on the PC (agenix, sops, the panel). A path in the Nix store is world-readable: tests only.
- **Time sync**: Kerberos fails with more than 5 minutes of clock skew. Set `ntpServers` to your DCs.
- **Hostnames of 15 characters or fewer** (NetBIOS limit). Evaluation fails for a longer `networking.hostName`; for PCs named at install time the join service refuses and logs why.

Decisions: `gpoAccessControl` defaults to `permissive` (GPO logon rights are evaluated and logged but not
enforced), because enforcing against a freshly built domain can lock everyone out; move to `enforcing`
once `journalctl -u sssd` shows no unexpected denials. Members of `adminGroups` get sudo, and because
the school profile limits the sudo binary to `wheel`, this module lifts that limit when `adminGroups`
is non-empty (sudoers still decides who may use it). DNS dynamic updates are off.

Not covered yet: Entra ID (Himmelblau, separate work), Group Policy beyond logon rights, SMB home
drives and mapped drives (pam_mount or autofs with Kerberos), 802.1X Wi-Fi with machine certificates,
PaperCut. Tested only on a text console: SDDM and the lock screen have PAM services with home-folder
creation enabled, but a graphical domain sign-in is not exercised by the VM test.

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
  school's directory: AD via SSSD (`directory` module); Entra ID via Himmelblau is future work.

## Out of scope (for now)

- Entra ID sign-in (Himmelblau; Active Directory is covered, see below)
- Group Policy, SMB home/mapped drives, 802.1X Wi-Fi with machine certificates, PaperCut (see "Active Directory")
- Web filtering
- Secure Boot (Lanzaboote)
- Installer and netboot images

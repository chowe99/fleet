# CodeRed Fleet

Managed NixOS desktops for schools and businesses moving off Windows: a
Windows-style KDE Plasma 6 desktop, LibreOffice, and every PC managed as code
from one flake.

## Layout

| Path | What |
|------|------|
| `flake.nix` | `lib.mkUsers`, `lib.mkFleet`, `lib.mkInstaller`, modules, template, `school-vm`, `demo-lab` + `demo-image` + `demo-lab-installer`, checks |
| `modules/base.nix` | installable image: UEFI systemd-boot, disko layout, generic hardware |
| `modules/desktop.nix` | `nixosModules.desktop`: Plasma 6 with a bottom taskbar, start menu and pinned apps (`desktop-layout.js`), LibreOffice, en_AU |
| `modules/school.nix` | `nixosModules.school`: desktop plus lockdown (no sudo/nix for non-admins, USB storage blocked, Firefox policies, KDE Kiosk, screen lock, no app store) |
| `modules/agent.nix` | `nixosModules.agent` (`codered.fleet.agent`): enrols with the panel, reports, applies target revisions, remote actions (reboot, update, lock, unlock, wipe) |
| `modules/encryption.nix` | `nixosModules.encryption` (`codered.fleet.encryption`): LUKS2 root, TPM2 unlock, recovery key escrowed with the panel |
| `modules/image.key` | the images' LUKS key: public on purpose, replaced on each PC's first boot |
| `modules/installer.nix`, `installer.sh` | the unattended USB-stick installer (`lib.mkInstaller`) |
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

For a lost or stolen PC:

- **Lock** ends every non-root session and refuses every login but root's (console, display manager,
  SSH) until **Unlock**. It survives reboots: the state is `/var/lib/fleet-agent/locked`, and
  `fleet-lock.service` re-creates `/run/nologin` at boot, before the login prompts start. Logins are
  refused by `pam_nologin`, which NixOS does not ship in its PAM stacks; the agent module adds it first
  in the account stack of `login` (which sddm, sddm-autologin and gdm include), `sshd`, lightdm and
  greetd. Root stays usable as the break-glass account. Every report carries `"locked": true|false`.
- **Wipe** destroys every LUKS keyslot of the encrypted root (`cryptsetup erase`), then powers the PC
  off. Without the keys the data is unreadable for good, and the PC no longer boots: reinstall it from
  the image. It is refused (`failed`, with the reason) unless the PC is built with
  `codered.fleet.agent.allowWipe = true` (off by default), has `codered.fleet.encryption` on, and is
  locked. The agent reports `done` first and wipes only once the panel has that report; if the report
  does not get through, nothing is wiped and the panel sends the action again.

## Disk encryption

`codered.fleet.encryption.enable = true` (on in `demo-lab`) gives a PC a LUKS2-encrypted root that
unlocks through the TPM2 with no password, plus a recovery key held by the panel, much like BitLocker.

**How it works.** The image (`.#demo-image`, built by disko) formats the root partition as LUKS2 with
the image key, `modules/image.key`. That key is **not secret**: it is in the repo, the Nix store, the
initrd and every image, and every PC flashed from one image shares it (and, until first boot, the same
volume key). On the first boot the initrd opens the disk with it, without a password, and
`fleet-encryption.service` then, in this order:

1. replaces the volume key by online re-encryption of the mounted root (`cryptsetup reencrypt`): the
   PC stays usable, and progress is kept in the LUKS2 header, so after a crash or power cut it resumes
   where it stopped. On a laptop it waits for mains power;
2. enrols the TPM2 (`systemd-cryptenroll --tpm2-pcrs=7`) and proves the TPM really unlocks the disk;
3. makes a recovery key (`systemd-cryptenroll --recovery-key`) and checks it opens the disk;
4. escrows it: `POST /api/v1/escrow` with the agent's device token, body
   `{"recovery_key": "...", "luks_uuid": "..."}`, expecting `200 {"ok": true}`;
5. only then removes the image key, and checks it no longer opens the disk.

Each step is idempotent and checked against the LUKS2 header (`cryptsetup luksDump /dev/...` shows a
`codered-fleet` token with the progress). Until step 5 the image key keeps working, so a failure at any
step leaves the PC bootable exactly as it came. The service retries every minute until it is done;
on later boots it checks, logs one line and exits.

Later boots unlock through the TPM2. If the TPM refuses (see below), the boot screen asks for the
recovery key, as often as needed: IT reads it from the panel.

**Unlock order at boot.** `fleet-image-key.service` (initrd) tries the image key once, with no prompt;
then `systemd-cryptsetup` tries the TPM2 token, then asks for the recovery key. The image key is
deliberately not the crypttab key file: when `tpm2-device=` is set, systemd-cryptsetup reads a key file
as a TPM2-sealed blob and never looks at the TPM2 token in the header, so a PC whose image key had been
removed would stop at a password prompt on every boot.

**Recovery-key escrow.** The key exists in plaintext only in the memory of `fleet-encryption`: it is
never logged, written to disk, or passed on a command line. While the panel cannot take it (offline,
an error), the service keeps it in memory and retries every minute; the image key stays meanwhile. If
the PC restarts before the panel confirmed it, its keyslot is removed and a new key made and sent, so
the panel can receive more than one key for a `luks_uuid`: only the most recent one is valid.

**No TPM.** With the TPM off in the firmware (or a VM without one) nothing is changed: the disk stays
unlocked by the shared image key, which protects nothing. The service logs this clearly and checks
again every minute, so turning on the TPM (fTPM on AMD, PTT on Intel) later finishes the setup without
a reinstall. A PC is never left without a working way in.

**PCR 7.** The disk key is sealed to PCR 7, the Secure Boot policy: whether Secure Boot is on and its
keys. Unlike the PCRs that measure the firmware, bootloader or kernel, it does not change when NixOS,
the kernel or systemd-boot update, so updates never trigger the recovery screen. Turning Secure Boot on
or off, changing its keys, or a firmware/dbx update that changes them does: enter the recovery key,
then re-enrol (`systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 <device>`).

**Honest limits.**

- Without Secure Boot, PCR 7 only records "Secure Boot is off", so the TPM will release the key to any
  OS booted on that PC. Encryption protects a disk taken out of its PC (a stolen or disposed drive);
  it does not stop someone booting a USB stick on the stolen PC itself and unlocking it with the TPM.
  The fixes are a TPM+PIN mode (follow-up) and Secure Boot with lanzaboote (phase 2), which makes
  PCR 7 mean "our signed boot chain".
- Until first boot finishes (and forever on a PC without a TPM) the disk opens with the public image key.
- Lock and wipe act at the PC's next check-in (up to 15 minutes, sooner after a reboot), and only if it
  reaches the panel. A thief who never connects it to a network is stopped only by the encryption.
- Root can always log in on a locked PC: protect the root password like any admin credential.
- A wipe destroys the keys, not the data area; without the keys it is unreadable ciphertext.

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

## Install PCs

`lib.mkInstaller { target = <one group from mkFleet>; }` builds a USB-stick installer for that group;
`.#demo-lab-installer` is demo-lab's. The stick carries the whole group, so the install needs the network
only to reach the panel. Nobody touches the keyboard.

1. **Write the image** to a USB stick (at least the size of the image, a few GB):

   ```sh
   nix build .#demo-lab-installer
   sudo dd if=result/fleet-installer.raw of=/dev/sdX bs=4M conv=fsync status=progress
   ```

   On Windows, use Rufus in "DD image" mode. Writing erases the stick.
2. **Drop `fleet/install.json`** onto the stick's FAT partition (Windows shows it as `FLEET`; there is a
   `fleet` folder with a README and an example):

   ```json
   {"enroll_token": "<panel > Settings > Enrol token>", "hostname": "office-07"}
   ```

   | Field | |
   |-------|-|
   | `enroll_token` | required; the installed PC enrols with it, and the installer checks it with the panel first |
   | `hostname` | optional; written to `/etc/hostname`. Without it the PC takes its name from DHCP. One stick installs many PCs, so change it per PC or leave it out |
   | `disk` | needed only when the PC has more than one internal disk: a name (`nvme0n1`, `sda`), a `/dev/...` path, or the disk's serial number |
   | `reinstall` | `true` to install over a PC that already runs Fleet (it refuses otherwise) |

   A PC prepared by the Windows migration script already has `fleet\install.json` on its own EFI system
   partition; then the stick needs none. The stick's own file wins when both exist. In Notepad, save as
   "All files", or the name becomes `install.json.txt`.
3. **Boot the PC from the stick** with a network cable plugged in: the firmware's one-time boot menu
   (F12, F11, F9 or Esc). UEFI only, and Secure Boot must be off (the installer is not signed yet).

What it does, in order, with every internal disk read-only until the last check has passed:

1. finds `fleet/install.json` (the stick first, then any FAT partition on the PC);
2. picks the disk: the only internal disk, or the one `disk` names. USB disks and the stick itself are
   never candidates;
3. refuses if any internal disk already holds a Fleet install;
4. tells the panel `installing` (`POST /api/v1/migration-status`, `{serial, status, detail}`, with
   `Authorization: Bearer <enrol token>`), retrying for `codered.fleet.installer.panelWait` (default
   5 minutes) while the panel does not answer. A 404 (the panel never saw this PC's Windows inventory)
   is fine; a 401 is a refusal;
5. wipes the disk and lays it out with the group's own disko layout (`modules/base.nix`): LUKS2 opened by
   the public image key, as from `.#demo-image`, but with fresh partition, LUKS and file system UUIDs and
   a fresh volume key on each PC;
6. copies the group from the stick (`nixos-install`), writes the enrol token to the group's
   `codered.fleet.agent.enrollTokenFile` (mode 0600; not when that file is provided at run time, like
   demo-lab's over QEMU fw_cfg) and the hostname to `/etc/hostname`;
7. adds a firmware boot entry for the installed disk, puts it first and makes it the next boot, then
   restarts. The PC starts alone: it unlocks with the image key, enrols, and sets up its disk encryption
   (README "Disk encryption").

If anything fails after `installing`, the panel gets `failed` with a short reason, the screen shows it,
and the PC powers off after 5 minutes: its disk was being replaced, so it no longer starts Windows.

**Refusals.** Each one leaves every disk exactly as it was, shows the reason on the screen for 30 seconds,
then restarts, so a PC booted from the stick once comes back as Windows:

| Cause | The screen says | The panel hears |
|-------|-----------------|-----------------|
| no `fleet/install.json` anywhere | "No fleet/install.json was found" (or "rename install.json.txt") | nothing |
| `install.json` is not JSON, has no `enroll_token`, or a bad `hostname` | which of these | nothing |
| the PC already runs Fleet | "This PC already runs CodeRed Fleet"; the restart goes straight into Fleet | nothing |
| more than one internal disk and no `disk` | the disks to choose from | `failed`, listing them |
| `disk` is not an internal disk, there is no internal disk, or it is too small | why | `failed`, with the reason |
| the panel does not answer within `panelWait` | "Could not reach the panel at ..." | nothing (it cannot) |
| the panel refuses the enrol token (401) | "The panel ... refused the enrol token" | nothing (the token was refused) |

The installer prints on the screen; everything, including the detail of each step, also goes to the
serial port.

### Installing over the network (the Windows migration script)

The USB image carries the whole group (gigabytes), which does not fit on a Windows PC's own EFI system
partition: Windows' is often 100 MB. The network installer is the same installer in two parts. The small
part, `installer.efi` (a unified kernel image, at most 48 MiB), is what the migration script
(`scripts/windows/fleet-migrate.ps1` in fleet-panel) copies to `\EFI\fleet\installer.efi` on the PC's own
EFI partition, next to `fleet\install.json`, before it makes it the next boot only (BootNext) and restarts.
The PC then runs from RAM and fetches the rest:

1. **Its own files** from `net.url`, checked against a SHA-256 built into `installer.efi`. A wrong or
   missing file is refused.
2. **The group's system** from a binary cache at `net.cacheUrl`, and only when it is signed by
   `net.cachePublicKey`. The installer checks the whole closure is there and signed before it wipes
   anything.

It then does everything the USB installer does (tells the panel `installing`, wipes and lays out the disk
with the group's own disko layout, installs, sets the firmware to start the new system, restarts). Here the
disk holding the EFI partition it booted from is the one it installs on; "never the boot medium" applies
to the USB stick, not to this. It still refuses a PC that already runs Fleet, and USB disks.

**Build it.** Set the options in the installer's `modules`:

```nix
installer = fleet.lib.mkInstaller {
  target = self.nixosConfigurations.office;
  modules = [{
    codered.fleet.installer.net = {
      url = "https://fleet.example.com/installer";       # where www/ is published
      cachePublicKey = "fleet-cache-1:...=";              # nix key generate-secret / convert-secret-to-public
      # cacheUrl = "https://cache.example.com";          # default: "<url>/cache"
    };
  }];
};
# installer.config.system.build.netInstaller is a directory: installer.efi and www/
```

**Publish `www/`** at `net.url`: copy its files (one squashfs, named by its hash) to any web server, so
that `<net.url>/stage2-<hash>.squashfs` downloads. Plain HTTP is fine: the hash is built into
`installer.efi`, not taken from the server (use HTTPS anyway for the cache, below, if it crosses a network
you do not trust; the signature protects it either way). It is a few hundred MB and is read into the PC's
RAM, so a PC needs about 3 GB of RAM or more (the installer itself keeps under 4 GB).

**Fill and sign the cache** with the group's system (the closure of `target.config.system.build.toplevel`),
on a machine that has it built. Do this again for every revision of the group you install new PCs from:

```sh
# once: the key. Keep the secret key private; its public half goes in net.cachePublicKey.
nix key generate-secret --key-name fleet-cache-1 > fleet-cache.sec
nix key convert-secret-to-public < fleet-cache.sec > fleet-cache.pub

# each revision: copy the system into a cache directory, then sign it (all of its closure)
top=$(nix build .#nixosConfigurations.office.config.system.build.toplevel --no-link --print-out-paths)
nix copy --to 'file:///srv/fleet-cache?compression=zstd' "$top"
nix store sign --store 'file:///srv/fleet-cache' --key-file fleet-cache.sec --recursive "$top"
```

Publish `/srv/fleet-cache` at `net.cacheUrl` (default `<net.url>/cache`, i.e. a `cache/` folder next to the
installer's files). `nix copy --to s3://...` or any other binary cache works too, as long as the paths are
signed with the key. Paths the cache lacks, or that are unsigned or signed by another key, make the
installer report `failed` to the panel with the reason ("cache" in the detail) and restart; nothing is
touched.

**Refusals** are the table above, plus two that happen before any `install.json` is read, in the part that
fits on the EFI partition:

| Cause | The screen says | The panel hears |
|-------|-----------------|-----------------|
| no network (no wired card got an address by DHCP in 90 seconds) | "No network" | nothing (it does not know the panel yet) |
| nothing at `net.url`, or the download does not match its built-in hash | what failed | nothing |
| the cache lacks the system, or it is not signed by `cachePublicKey` | "The binary cache ... cannot supply ..." | `failed`, with "cache" and the reason |

Each of them leaves every disk as it was, waits 30 seconds, and restarts. Because the migration script's
one-time boot is used up by then and the installer sets no new one, the PC comes back as Windows.

Limits: wired network cards only (a list of common drivers: Intel e1000e/igb/igc/ixgbe, Realtek r8169 and
r8152 USB, Broadcom tg3/bnxt, Aquantia atlantic, and virtio); DHCP on every wired card in turn; UEFI with
Secure Boot off, as for the USB stick.

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
- Secure Boot (Lanzaboote); TPM+PIN unlock
- Netboot (PXE, HTTP boot) installs: the network installer below is started from a PC's own EFI partition

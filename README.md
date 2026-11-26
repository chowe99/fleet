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
| `modules/agent.nix` | `nixosModules.agent` (`codered.fleet.agent`): enrols with the panel, reports, applies target revisions, remote actions (reboot, update, lock, unlock, wipe) |
| `modules/encryption.nix` | `nixosModules.encryption` (`codered.fleet.encryption`): LUKS2 root, TPM2 unlock, recovery key escrowed with the panel |
| `modules/image.key` | the images' LUKS key: public on purpose, replaced on each PC's first boot |
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
- Secure Boot (Lanzaboote); TPM+PIN unlock
- Installer and netboot images

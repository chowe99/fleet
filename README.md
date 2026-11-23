# CodeRed Fleet

Managed NixOS desktops for schools and businesses moving off Windows: a
Windows-style KDE Plasma 6 desktop, LibreOffice, and every PC managed as code
from one flake.

## Layout

| Path | What |
|------|------|
| `flake.nix` | `lib.mkUsers`, `lib.mkFleet`, modules, template, `school-vm`, checks |
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
password `demo`. That password exists only in this VM's configuration.

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

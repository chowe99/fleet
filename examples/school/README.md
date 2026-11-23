# Our school's PCs

## Add a person: add a folder

Every person who isn't a generated student has a folder in `users/`:

```sh
nix run .#new-user -- jsmith        # creates users/jsmith/default.nix
$EDITOR users/jsmith/default.nix    # name, and extraGroups = ["wheel"] for IT staff
git add users/jsmith && git commit -m "add jsmith" && git push
```

The file is merged into that person's account, so it can also change a generated
student (`users/student7/default.nix`). Delete the folder to remove the person.
Nix only sees files that git tracks, so always `git add` new folders.

## Students

`generate.student = 30;` in `flake.nix` creates `student1` to `student30`. Change
the number to add or remove students. Home folders are created when someone
first logs in, so a large number costs nothing on PCs nobody uses.

## Groups of PCs

Each entry in `groups` (here `lab` and `library`) is one system image, shared by
every PC in that group. Put settings for one group in its `modules`, and
settings for every PC in `common`.

## Rolling out a change

Commit and push. The CodeRed panel shows each PC's current revision and decides
when PCs move to a new one. PCs install updates in the background and switch to
them at the next restart, so nothing changes during a lesson.

## Administrators

Only accounts with `extraGroups = ["wheel"]` (like `itadmin`) can use `sudo`.
Everyone else uses the locked-down school desktop: no app store, USB drives
blocked, Firefox and the taskbar managed by these settings.

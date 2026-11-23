{
  description = "CodeRed Fleet: managed NixOS desktops that look like Windows";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    disko,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    inherit (nixpkgs) lib;
  in {
    lib = {
      # A NixOS module declaring every user: <prefix>1..<prefix>N for each entry
      # in `generate`, plus one user per folder `dir/<name>/default.nix` (an
      # attrset merged over the generated defaults, so it can override them).
      mkUsers = {
        generate ? {},
        dir ? null,
      }: let
        # Normal, non-admin accounts. Homes are made at first login
        # (pam_mkhomedir), not for every account on every PC at activation.
        defaults = {
          isNormalUser = true;
          createHome = false;
        };
        generated = lib.concatMapAttrs (prefix: count:
          lib.genAttrs (lib.genList (i: "${prefix}${toString (i + 1)}") count) (_: {}))
        generate;
        folders = lib.optionalAttrs (dir != null) (
          lib.mapAttrs (name: _: import (dir + "/${name}"))
          (lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir))
        );
      in {
        users.users = lib.mapAttrs (_: user: defaults // user) (generated // folders);
        security.pam.services = lib.genAttrs ["login" "su" "sshd"] (_: {makeHomeDir = true;});
      };

      # One nixosSystem per group of PCs (never per PC): every machine in a
      # group shares one closure; its name and identity come at enrolment.
      mkFleet = {
        groups,
        users ? {},
        rev ? null,
      }:
        lib.mapAttrs (name: group:
          lib.nixosSystem {
            modules =
              [
                disko.nixosModules.disko
                ./modules/base.nix
                self.nixosModules.agent
                self.nixosModules.${group.profile}
                (self.lib.mkUsers users)
                {
                  codered.fleet.agent.group = name;
                  codered.fleet.agent.profile = lib.mkDefault group.profile;
                  system.configurationRevision = lib.mkIf (rev != null) rev;
                }
              ]
              ++ group.modules or [];
          })
        groups;
    };

    nixosModules = {
      agent = ./modules/agent.nix;
      desktop = ./modules/desktop.nix;
      school = ./modules/school.nix;
    };

    templates.school = {
      path = ./examples/school;
      description = "A school's fleet: lab and library PCs, students from a loop, staff from folders";
    };

    # `nix run .#new-user -- <name>` in a customer's fleet repo: one folder per person.
    packages.${system}.new-user = pkgs.writeShellApplication {
      name = "new-user";
      text = ''
        name=''${1:-}
        if [[ ! $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
          echo "usage: nix run .#new-user -- <name>   (lower-case letters, digits, - and _)" >&2
          exit 1
        fi
        [[ -f flake.nix && -d users ]] || { echo "run this from your fleet repo (next to flake.nix and users/)" >&2; exit 1; }
        dir=users/$name
        [[ ! -e $dir ]] || { echo "$dir already exists" >&2; exit 1; }
        mkdir "$dir"
        cat > "$dir/default.nix" <<EOF
        # $name: merged into users.users.$name on every PC in the fleet.
        {
          description = "$name";
          # extraGroups = ["wheel"]; # uncomment to make $name an administrator
        }
        EOF
        echo "Created $dir/default.nix. Edit it, then: git add $dir && git commit"
      '';
    };

    # The school image as a QEMU VM. Demo password only here, never in lib.
    nixosConfigurations.school-vm =
      (self.lib.mkFleet {
        rev = self.rev or self.dirtyRev or null;
        groups.lab = {
          profile = "school";
          modules = [
            {
              networking.hostName = "school-vm";
              users.users = lib.genAttrs ["student1" "teacher1" "itadmin"] (_: {initialPassword = "demo";});
              virtualisation.vmVariant.virtualisation = {
                memorySize = 4096;
                cores = 2;
              };
            }
          ];
        };
        users = {
          generate.student = 30;
          dir = ./examples/school/users;
        };
      }).lab;

    apps.${system} = {
      new-user = {
        type = "app";
        program = lib.getExe self.packages.${system}.new-user;
      };
      school-vm = {
        type = "app";
        program = lib.getExe self.nixosConfigurations.school-vm.config.system.build.vm;
      };
    };

    checks.${system} = {
      fleet = import ./tests/fleet.nix {inherit self pkgs;};
      school = import ./tests/school.nix {inherit self pkgs;};
    };
  };
}

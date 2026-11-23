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

    checks.${system} = {
      fleet = import ./tests/fleet.nix {inherit self pkgs;};
      school = import ./tests/school.nix {inherit self pkgs;};
    };
  };
}

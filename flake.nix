{
  description = "CodeRed Fleet: managed NixOS desktops that look like Windows";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # To build: lib.mkUsers, lib.mkFleet, nixosModules.school (see tests/).
    lib = {};
    nixosModules = {};

    checks.${system} = {
      fleet = import ./tests/fleet.nix {inherit self pkgs;};
      school = import ./tests/school.nix {inherit self pkgs;};
    };
  };
}

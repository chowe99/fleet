{
  description = "Our school's PCs, managed with CodeRed Fleet";

  # CodeRed gives you this URL when your service starts.
  inputs.fleet.url = "github:chowe99/fleet";

  outputs = {
    self,
    fleet,
  }: let
    lib = fleet.inputs.nixpkgs.lib;
    # Written by the CodeRed panel (it commits here); edit settings there, not by hand.
    settings =
      if builtins.pathExists ./fleet-settings.json
      then lib.importJSON ./fleet-settings.json
      else {};
    # The panel serves this repo as a tarball, which has no `self.rev`, and adds `.fleet-rev`
    # holding the commit SHA. Without a revision, PCs report "unknown" as their version.
    rev =
      self.rev
      or self.dirtyRev
      or (
        if builtins.pathExists ./.fleet-rev
        then lib.removeSuffix "\n" (lib.trim (builtins.readFile ./.fleet-rev))
        else null
      );
    # Settings shared by every group of PCs.
    common = {
      codered.fleet.agent = {
        enable = true;
        url = "https://fleet.codered.lol"; # the CodeRed panel
        enrollTokenFile = "/var/lib/fleet-agent/enroll-token"; # written at install
        # PCs fetch this config from the panel, authenticating with their device token.
        flakeUrlTemplate = "https://fleet.codered.lol/api/v1/config/{rev}.tar.gz";
        # flake = "git+https://git.school.example/it/fleet"; # optional fallback if the template is unset
      };
    };
    # mkForce: a group's own homepage beats the panel-wide one in fleet-settings.json.
    homepage = url: {programs.firefox.policies.Homepage.URL = lib.mkForce url;};
  in {
    # One image per group of PCs, not per PC.
    nixosConfigurations = fleet.lib.mkFleet {
      inherit rev settings;
      groups = {
        lab = {
          profile = "school";
          modules = [common]; # homepage comes from fleet-settings.json
        };
        library = {
          profile = "school";
          modules = [common (homepage "https://library.school.example/")];
        };
      };
      users = {
        generate.student = 30; # student1 .. student30
        dir = ./users; # one folder per person: users/<name>/default.nix
      };
    };

    apps.x86_64-linux.new-user = fleet.apps.x86_64-linux.new-user;
  };
}

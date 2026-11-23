{
  description = "Our school's PCs, managed with CodeRed Fleet";

  # CodeRed gives you this URL when your service starts.
  inputs.fleet.url = "git+https://git.codered.example/fleet";

  outputs = {
    self,
    fleet,
  }: let
    # Settings shared by every group of PCs.
    common = {
      codered.fleet.agent = {
        enable = true;
        url = "https://fleet.codered.example"; # your CodeRed panel
        enrollTokenFile = "/var/lib/fleet-agent/enroll-token"; # written at install
        flake = "git+https://git.school.example/it/fleet"; # this repository
      };
    };
    homepage = url: {programs.firefox.policies.Homepage.URL = url;};
  in {
    # One image per group of PCs, not per PC.
    nixosConfigurations = fleet.lib.mkFleet {
      rev = self.rev or self.dirtyRev or null;
      groups = {
        lab = {
          profile = "school";
          modules = [common (homepage "https://www.school.example/")];
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

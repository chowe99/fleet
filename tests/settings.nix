# LOCKED acceptance test: do not edit, weaken, skip or delete.
# Customer settings live as data (fleet-settings.json in the customer's config repo, written by the
# panel) and mkFleet turns them into the real options. No settings → today's defaults.
# Run: nix build .#checks.x86_64-linux.settings
{
  self,
  pkgs,
}: let
  settings = builtins.fromJSON (builtins.readFile ./fixtures/fleet-settings.json);
  fleet = self.lib.mkFleet {
    groups.lab.profile = "school";
    users.dir = ./fixtures/users;
    inherit settings;
  };
  c = fleet.lab.config;
  profiles = builtins.attrValues c.networking.networkmanager.ensureProfiles.profiles;
  plain = (self.lib.mkFleet {groups.lab.profile = "school";}).lab.config;
in
  assert c.codered.fleet.school.allowUsbStorage;
  assert c.programs.firefox.policies.Homepage.URL == "https://portal.school.example/";
  assert c.time.timeZone == "Australia/Sydney";
  assert builtins.any (p: (p.wifi.ssid or null) == "SchoolNet") profiles;
  assert builtins.elem "Library" (map (p: p.name) c.hardware.printers.ensurePrinters);
  assert c.users.users ? student3 && !(c.users.users ? student4);
  assert c.users.users.teacher1.description == "Teacher One";
  assert !plain.codered.fleet.school.allowUsbStorage;
  assert plain.time.timeZone == "Australia/Perth";
  assert builtins.isString c.system.build.toplevel.drvPath;
    pkgs.runCommand "fleet-settings-ok" {} "touch $out"

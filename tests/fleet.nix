# LOCKED acceptance test: do not edit, weaken, skip or delete.
# The fleet generator builds ONE system image per group of machines (a lab,
# the library, staff laptops), never one per PC, so 1,000 lab PCs share one
# build. Users come from a loop (student1..studentN) plus one folder per user
# under users/, which the customer's IT department manages.
# Run: nix build .#checks.x86_64-linux.fleet
{
  self,
  pkgs,
}: let
  fleet = self.lib.mkFleet {
    groups = {
      lab = {profile = "school";};
      library = {profile = "school";};
    };
    users = {
      generate.student = 500;
      dir = ./fixtures/users;
    };
  };
  lab = fleet.lab.config;
in
  assert builtins.attrNames fleet == ["lab" "library"];
  assert lab.users.users ? student1 && lab.users.users ? student500;
  assert !(lab.users.users ? student501) && !(lab.users.users ? student0);
  assert lab.users.users.teacher1.description == "Teacher One";
  assert lab.users.users.student2.description == "Student Two";
  assert !(builtins.elem "wheel" lab.users.users.student1.extraGroups);
  # The image must be a complete, installable system, not just evaluate users.
  assert builtins.isString fleet.lab.config.system.build.toplevel.drvPath;
    pkgs.runCommand "fleet-generator-ok" {} "touch $out"

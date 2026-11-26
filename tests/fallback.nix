# LOCKED acceptance test: do not edit, weaken, skip or delete.
# Automatic fallback after a bad update. A new version is tried a limited number of times; a boot is
# good only when it reaches boot-complete.target, which requires the configured units to be running.
# A version whose required unit fails, or that never finishes starting, is abandoned without anyone
# touching the PC: it restarts itself and comes back on the last good version, and the next check-in
# tells the panel the update failed. A good update is marked good and stays, boot after boot.
# tests/fixtures/boot-helpers.py drives the VM through the restarts and may be edited for mechanics only.
# Run: nix build .#checks.x86_64-linux.fallback -L
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "fallback";

  nodes.machine = {
    lib,
    pkgs,
    ...
  }: {
    imports = [self.nixosModules.agent self.nixosModules.fallback];

    virtualisation = {
      useBootLoader = true;
      useEFIBoot = true;
      memorySize = 1024;
    };
    boot.loader.systemd-boot.enable = true;

    codered.fleet.fallback = {
      enable = true;
      tries = 2;
      requiredUnits = ["critical.service"];
      bootTimeout = "120s";
    };
    systemd.services.critical = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
      };
    };

    codered.fleet.agent = {
      enable = true;
      url = "http://127.0.0.1:8080";
      enrollTokenFile = pkgs.writeText "enroll-token" "enroll-abc";
      profile = "school";
    };
    systemd.services.mock-panel = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./mock_panel.py} 8080 /var/lib/mock-panel";
    };

    environment.etc."fleet-test-version".text = "good";
    specialisation = {
      good2.configuration.environment.etc."fleet-test-version".text = lib.mkForce "good2";
      broken.configuration = {
        environment.etc."fleet-test-version".text = lib.mkForce "broken";
        systemd.services.critical.serviceConfig.ExecStart = lib.mkForce "${pkgs.coreutils}/bin/false";
      };
      stuck.configuration = {
        environment.etc."fleet-test-version".text = lib.mkForce "stuck";
        systemd.services.hang = {
          wantedBy = ["multi-user.target"];
          before = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
            TimeoutStartSec = "infinity";
          };
        };
      };
    };
  };

  testScript = {nodes, ...}: let
    spec = name: nodes.machine.specialisation.${name}.configuration.system.build.toplevel;
  in ''
    import json

    ${builtins.readFile ./fixtures/boot-helpers.py}

    VERSIONS = {"good2": "${spec "good2"}", "broken": "${spec "broken"}", "stuck": "${spec "stuck"}"}

    def version():
        return machine.succeed("cat /etc/fleet-test-version").strip()

    def stage(name):
        # What a staged update does (nixos-rebuild boot): a new generation, made the default boot entry.
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {VERSIONS[name]}")
        machine.succeed(f"{VERSIONS[name]}/bin/switch-to-configuration boot")

    def reboot_into_good():
        machine.shutdown()
        return boot_until_good(machine, 6)

    machine.start()
    machine.wait_for_unit("multi-user.target")
    assert version() == "good"

    with subtest("a good update boots, is marked good, and stays"):
        stage("good2")
        assert reboot_into_good() == 1
        assert version() == "good2"
        for _ in range(3):
            assert reboot_into_good() == 1
            assert version() == "good2", "a good version must not be abandoned on later boots"

    with subtest("a version whose required unit fails is abandoned by itself"):
        stage("broken")
        starts = reboot_into_good()
        assert starts > 1, "the broken version was tried before falling back"
        assert version() == "good2", "back on the last good version"

    with subtest("the next check-in tells the panel the update failed"):
        machine.wait_for_unit("mock-panel.service")
        machine.wait_for_open_port(8080)
        machine.succeed("rm -f /var/lib/mock-panel/report.json")
        machine.succeed("systemctl start fleet-agent.service")
        machine.wait_until_succeeds("test -s /var/lib/mock-panel/report.json")
        report = json.loads(machine.succeed("cat /var/lib/mock-panel/report.json"))
        assert report.get("last_update") is not None and report["last_update"].get("ok") is False, report

    with subtest("the abandoned version stays abandoned"):
        assert reboot_into_good() == 1
        assert version() == "good2"

    with subtest("a version that never finishes starting is abandoned by itself"):
        stage("stuck")
        starts = reboot_into_good()
        assert starts > 1, "the stuck version was tried before falling back"
        assert version() == "good2"
  '';
}

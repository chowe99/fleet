# LOCKED acceptance test: do not edit, weaken, skip or delete.
# A school PC with the French ANSSI hardening (Securix's modules/anssi, MIT) at "intermediary":
# rules are applied or excluded with a written reason, the kernel really is hardened, and nothing a
# school needs breaks: lockdown, the agent, browser/Nix sandboxes (user namespaces), Plasma for a student.
# Run: nix build .#checks.x86_64-linux.hardening -L
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "hardening";

  nodes.machine = {pkgs, ...}: {
    imports = [
      self.nixosModules.school
      (self.lib.mkUsers {
        generate.student = 2;
        dir = ./fixtures/users;
      })
    ];

    codered.fleet.hardening.level = "intermediary";

    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;

    services.displayManager.autoLogin = {
      enable = true;
      user = "student1";
    };

    codered.fleet.agent = {
      enable = true;
      url = "http://127.0.0.1:8080";
      enrollTokenFile = pkgs.writeText "enroll-token" "enroll-abc";
    };
    systemd.services.mock-panel = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./mock_panel.py} 8080 /var/lib/mock-panel";
    };
  };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")

    with subtest("the hardening level and every rule's outcome are recorded on the PC"):
        h = json.loads(machine.succeed("cat /etc/fleet/hardening.json"))
        assert h["level"] == "intermediary", h
        applied, excluded = set(h["applied"]), h["excluded"]
        assert applied and excluded is not None, h
        assert not applied & set(excluded), ("rule both applied and excluded", applied & set(excluded))
        for rule, reason in excluded.items():
            assert isinstance(reason, str) and reason.strip(), ("excluded without a reason", rule)
        assert "R11" in applied, ("Yama ptrace rule (intermediary) must apply", h)

    with subtest("the kernel is actually hardened"):
        assert machine.succeed("sysctl -n kernel.yama.ptrace_scope").strip() == "1"

    with subtest("school lockdown still holds"):
        machine.fail("id -nG student1 | grep -qw wheel")
        machine.fail("su - student1 -c 'sudo -n true'")
        machine.fail("modprobe usb-storage")
        machine.succeed("readlink -f /run/current-system/sw/bin/soffice | grep -i libreoffice")

    with subtest("browser and Nix sandboxes still work (user namespaces)"):
        machine.succeed("unshare --user --map-root-user true")
        machine.succeed("su - student1 -c 'unshare --user --map-root-user true'")

    with subtest("the fleet agent still enrolls and reports"):
        machine.wait_for_unit("mock-panel.service")
        machine.wait_for_open_port(8080)
        machine.succeed("systemctl start fleet-agent.service")
        machine.wait_until_succeeds("test -s /var/lib/mock-panel/report.json")
        report = json.loads(machine.succeed("cat /var/lib/mock-panel/report.json"))
        assert report["profile"] == "school", report

    with subtest("a student still lands on the Plasma desktop"):
        machine.wait_until_succeeds("pgrep -u student1 plasmashell", timeout=300)
        machine.sleep(30)
        machine.screenshot("hardened-desktop")
  '';
}

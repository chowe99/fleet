# LOCKED acceptance test: do not edit, weaken, skip or delete.
# Boots the school profile and checks the lockdown, LibreOffice, generated
# users, the fleet agent, and that a student lands on a Plasma desktop.
# Run: nix build .#checks.x86_64-linux.school -L   (screenshot in result/)
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "school";

  nodes.machine = {pkgs, ...}: {
    imports = [
      self.nixosModules.school
      (self.lib.mkUsers {
        generate.student = 3;
        dir = ./fixtures/users;
      })
    ];

    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;

    # Test-only: log a student straight in so the desktop can be screenshotted.
    services.displayManager.autoLogin = {
      enable = true;
      user = "student1";
    };

    # Test-only: point the agent at a stand-in panel.
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

    with subtest("users come from a loop and from IT-managed folders"):
        for n in (1, 2, 3):
            machine.succeed(f"id student{n}")
        machine.fail("id student4")
        machine.succeed("getent passwd student2 | grep -q 'Student Two'")
        machine.succeed("getent passwd teacher1 | grep -q 'Teacher One'")

    with subtest("students are not administrators"):
        for user in ("student1", "teacher1"):
            machine.fail(f"id -nG {user} | grep -qw wheel")
        machine.fail("su - student1 -c 'sudo -n true'")
        machine.fail("su - student1 -c 'nix-store -q --hash /run/current-system'")

    with subtest("LibreOffice is the office suite, and there is no app store"):
        machine.succeed("readlink -f /run/current-system/sw/bin/soffice | grep -i libreoffice")
        machine.fail("test -e /run/current-system/sw/bin/plasma-discover")

    with subtest("USB storage is blocked"):
        machine.fail("modprobe usb-storage")

    with subtest("browser and desktop settings are locked"):
        machine.succeed("grep -q BlockAboutConfig /etc/firefox/policies/policies.json")
        machine.succeed("grep -q 'KDE Action Restrictions' /etc/xdg/kdeglobals")

    with subtest("the fleet agent enrolls and reports to the panel"):
        machine.wait_for_unit("mock-panel.service")
        machine.wait_for_open_port(8080)
        machine.succeed("systemctl start fleet-agent.service")
        machine.wait_until_succeeds("test -s /var/lib/mock-panel/report.json")
        enroll = json.loads(machine.succeed("cat /var/lib/mock-panel/enroll.json"))
        assert enroll["enroll_token"] == "enroll-abc", enroll
        for key in ("hostname", "serial", "profile"):
            assert key in enroll, (key, enroll)
        report = json.loads(machine.succeed("cat /var/lib/mock-panel/report.json"))
        for key in ("hostname", "serial", "profile", "current_rev", "nixos_version", "uptime_s", "last_update"):
            assert key in report, (key, report)
        assert report["profile"] == "school", report
        auth = machine.succeed("cat /var/lib/mock-panel/report.auth").strip()
        assert auth == "Bearer dev-token-123", auth

    with subtest("a student lands on a Windows-style Plasma desktop"):
        machine.wait_until_succeeds("pgrep -u student1 plasmashell", timeout=300)
        machine.sleep(30)
        machine.screenshot("school-desktop")
  '';
}

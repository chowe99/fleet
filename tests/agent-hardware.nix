# LOCKED acceptance test: do not edit, weaken, skip or delete.
# The agent reports the PC's hardware with each check-in (for the panel's device page and asset
# register). Fast: the agent module alone, no desktop.
# Run: nix build .#checks.x86_64-linux.agent-hardware -L
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "agent-hardware";

  nodes.machine = {pkgs, ...}: {
    imports = [self.nixosModules.agent];
    virtualisation.diskSize = 2048;
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
  };

  testScript = ''
    import json

    machine.wait_for_unit("mock-panel.service")
    machine.wait_for_open_port(8080)
    machine.succeed("systemctl start fleet-agent.service")
    machine.wait_until_succeeds("test -s /var/lib/mock-panel/report.json")
    hw = json.loads(machine.succeed("cat /var/lib/mock-panel/report.json"))["hardware"]

    for key in ("vendor", "model", "cpu", "ram_mb", "disk_total_gb", "disk_free_gb", "battery"):
        assert key in hw, (key, hw)
    assert "QEMU" in (hw["vendor"] + hw["model"]), hw
    assert hw["cpu"], hw
    assert isinstance(hw["ram_mb"], int) and 500 < hw["ram_mb"] < 4096, hw
    assert isinstance(hw["disk_total_gb"], int) and hw["disk_total_gb"] >= 1, hw
    assert isinstance(hw["disk_free_gb"], int) and 0 <= hw["disk_free_gb"] <= hw["disk_total_gb"], hw
    assert hw["battery"] is None, hw  # a VM has no battery
  '';
}

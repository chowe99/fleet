# LOCKED acceptance test: do not edit, weaken, skip or delete.
# Remote actions on the PC: a normal reboot waits while someone is logged in (and says so); a forced
# one doesn't; the result is reported after the PC comes back. Unknown actions fail cleanly.
# Run: nix build .#checks.x86_64-linux.agent-actions -L
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "agent-actions";

  nodes.machine = {pkgs, ...}: {
    imports = [self.nixosModules.agent];
    users.users.alice = {
      isNormalUser = true;
      password = "alice";
    };
    codered.fleet.agent = {
      enable = true;
      url = "http://127.0.0.1:8080";
      enrollTokenFile = pkgs.writeText "enroll-token" "enroll-abc";
      profile = "school";
    };
    systemd.services.mock-panel = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./mock_panel_actions.py} 8080 /var/lib/mock-panel";
    };
  };

  testScript = ''
    import json

    def reports():
        out = machine.succeed("ls /var/lib/mock-panel | grep -c '^report-' || true").strip()
        return int(out or 0)

    def results(action_id):
        found = []
        for i in range(1, reports() + 1):
            r = json.loads(machine.succeed(f"cat /var/lib/mock-panel/report-{i}.json"))
            found += [x for x in (r.get("action_results") or []) if x.get("id") == action_id]
        return found

    def queue(actions):
        machine.succeed("echo " + json.dumps(json.dumps(actions)) + " > /var/lib/mock-panel/queue.json")

    def checkin():
        before = reports()
        machine.succeed("systemctl start fleet-agent.service")
        machine.wait_until_succeeds(f"test $(ls /var/lib/mock-panel | grep -c '^report-') -gt {before}")

    machine.wait_for_unit("mock-panel.service")
    machine.wait_for_open_port(8080)
    checkin()

    with subtest("someone is logged in: a normal reboot waits and says why"):
        machine.wait_until_tty_matches("1", "login: ")
        machine.send_chars("alice\n")
        machine.wait_until_tty_matches("1", "Password: ")
        machine.send_chars("alice\n")
        machine.wait_until_succeeds("loginctl list-sessions --no-legend | grep -q alice")
        queue([{"id": "a1", "type": "reboot", "force": False}])
        checkin()
        checkin()
        assert any(x["status"] == "deferred" for x in results("a1")), results("a1")
        machine.succeed("true")  # still running

    with subtest("unknown actions fail cleanly"):
        queue([{"id": "x1", "type": "explode", "force": False}])
        checkin()
        checkin()
        assert any(x["status"] == "failed" for x in results("x1")), results("x1")

    with subtest("a forced reboot happens anyway and is reported after boot"):
        queue([{"id": "a2", "type": "reboot", "force": True}])
        machine.execute("systemctl start --no-block fleet-agent.service")
        machine.wait_for_shutdown()
        machine.start()
        machine.wait_for_unit("mock-panel.service")
        machine.wait_for_open_port(8080)
        checkin()
        assert any(x["status"] == "done" for x in results("a2")), results("a2")
  '';
}

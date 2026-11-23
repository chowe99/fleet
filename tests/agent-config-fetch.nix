# LOCKED acceptance test: do not edit, weaken, skip or delete.
# Panel-hosted config: the PC fetches its organisation's config as a tarball from the panel,
# authenticating with its own device token via a private netrc that nix uses. The flake URL comes
# from flakeUrlTemplate with {rev} replaced by the ring's target revision.
# Run: nix build .#checks.x86_64-linux.agent-config-fetch -L
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "agent-config-fetch";

  nodes.machine = {pkgs, ...}: {
    imports = [self.nixosModules.agent];
    codered.fleet.agent = {
      enable = true;
      url = "http://127.0.0.1:8080";
      enrollTokenFile = pkgs.writeText "enroll-token" "enroll-abc";
      profile = "school";
      group = "lab";
      flakeUrlTemplate = "http://127.0.0.1:8080/api/v1/config/{rev}.tar.gz";
    };
    systemd.services.mock-panel = {
      wantedBy = ["multi-user.target"];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./mock_panel_config.py} 8080 /var/lib/mock-panel";
    };
  };

  testScript = ''
    import base64

    machine.wait_for_unit("mock-panel.service")
    machine.wait_for_open_port(8080)
    machine.execute("systemctl start fleet-agent.service")

    with subtest("the device token is given to nix for the panel's host only, privately"):
        machine.wait_until_succeeds("test -s /var/lib/fleet-agent/netrc")
        machine.succeed("grep -qx 'machine 127.0.0.1 login device password dev-token-123' /var/lib/fleet-agent/netrc")
        mode = machine.succeed("stat -c %a /var/lib/fleet-agent/netrc").strip()
        assert mode == "600", mode
        machine.succeed("grep -Eq '^netrc-file = /var/lib/fleet-agent/netrc$' /etc/nix/nix.conf")

    with subtest("an update fetches the config tarball from the panel with the device token"):
        machine.wait_until_succeeds("test -s /var/lib/mock-panel/config-fetch.auth", timeout=300)
        path = machine.succeed("cat /var/lib/mock-panel/config-fetch.path").strip()
        assert path == "/api/v1/config/abc123.tar.gz", path
        auth = machine.succeed("cat /var/lib/mock-panel/config-fetch.auth").strip()
        assert auth == "Basic " + base64.b64encode(b"device:dev-token-123").decode(), auth
  '';
}

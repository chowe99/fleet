# LOCKED acceptance test: do not edit, weaken, skip or delete.
# Active Directory sign-in: a fleet PC joins a real Samba AD domain (fixtures/samba-dc.nix) by itself
# at boot, retrying until the domain controller is reachable. Domain users sign in with their short
# name and AD password and get a home folder; a wrong password is refused; members of the AD group
# "Fleet Admins" are administrators and nobody else is; after one online sign-in, a user can still
# sign in with cached credentials while the domain controller is down; local accounts keep working.
# Run: nix build .#checks.x86_64-linux.directory -L
{
  self,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "directory";

  nodes.dc = ./fixtures/samba-dc.nix;

  nodes.client = {
    lib,
    nodes,
    pkgs,
    ...
  }: {
    imports = [self.nixosModules.directory];
    networking.nameservers = lib.mkForce [nodes.dc.networking.primaryIPAddress];
    virtualisation.memorySize = 1536;

    codered.fleet.directory = {
      enable = true;
      domain = "school.test";
      joinUser = "Administrator";
      joinPasswordFile = pkgs.writeText "join-password" "Adm1n-Passw0rd!";
      adminGroups = ["Fleet Admins"];
    };

    users.users.localadmin = {
      isNormalUser = true;
      password = "local";
    };
  };

  testScript = ''
    vt = [1]

    def sessions(user):
        out = client.execute(f"loginctl list-sessions --no-legend | grep -cw {user}")[1].strip()
        return int(out or 0)

    def type_login(user, password):
        # A fresh VT per attempt, so "Password: " on screen proves the username was really typed.
        vt[0] += 1
        n = vt[0]
        client.send_key(f"alt-f{n}")
        client.wait_until_succeeds(f"[ $(fgconsole) = {n} ]")
        client.wait_for_unit(f"getty@tty{n}.service")
        client.wait_until_tty_matches(str(n), "login: ")
        client.send_chars(f"{user}\n")
        client.wait_until_tty_matches(str(n), "Password: ")
        client.send_chars(f"{password}\n")

    def login_ok(user, password):
        before = sessions(user)
        type_login(user, password)
        client.wait_until_succeeds(f"[ $(loginctl list-sessions --no-legend | grep -cw {user}) -gt {before} ]", timeout=120)

    def login_refused(user, password):
        before = sessions(user)
        type_login(user, password)
        client.sleep(20)
        assert sessions(user) == before, f"{user} must not get a session"

    start_all()

    with subtest("a real Samba AD domain controller with users and an admin group"):
        dc.wait_for_unit("samba-ad-dc.service", timeout=900)
        for port in (53, 88, 389, 445):
            dc.wait_for_open_port(port, timeout=300)
        dc.succeed("samba-tool user create alice 'Alice-Passw0rd!' --given-name=Alice --surname=Student")
        dc.succeed("samba-tool user create bob 'Bob-Passw0rd!' --given-name=Bob --surname=Teacher")
        dc.succeed("samba-tool group add 'Fleet Admins'")
        dc.succeed("samba-tool group addmembers 'Fleet Admins' bob")

    with subtest("the PC joins the domain by itself"):
        client.wait_for_unit("multi-user.target")
        dc.wait_until_succeeds("samba-tool computer show CLIENT", timeout=900)
        client.wait_until_succeeds("id alice", timeout=600)
        assert "domain users" in client.succeed("id alice").lower(), client.succeed("id alice")

    with subtest("a domain user signs in with their AD password and gets a home folder"):
        login_ok("alice", "Alice-Passw0rd!")
        home = client.succeed("getent passwd alice | cut -d: -f6").strip()
        assert home, "alice has a home directory path"
        client.succeed(f"test -d {home} && [ $(stat -c %U {home}) = alice ]")

    with subtest("a wrong password is refused"):
        login_refused("alice", "Wrong-Passw0rd!")

    with subtest("members of 'Fleet Admins' are administrators, nobody else is"):
        client.wait_until_succeeds("id bob", timeout=300)
        client.succeed("sudo -l -U bob | grep -q '(ALL'")
        client.fail("sudo -l -U alice | grep -q '(ALL'")

    with subtest("cached sign-in works while the domain controller is down"):
        dc.shutdown()
        login_ok("alice", "Alice-Passw0rd!")

    with subtest("local accounts keep working"):
        login_ok("localadmin", "local")
  '';
}

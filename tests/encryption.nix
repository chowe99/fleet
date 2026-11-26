# LOCKED acceptance test: do not edit, weaken, skip or delete.
# Disk encryption and lost/stolen PC actions, end to end in one VM with a TPM:
# - A PC arrives from the image LUKS2-encrypted with the image's shared, temporary key and boots
#   without a password. On first boot it replaces the volume key (every PC from one image shared it),
#   enrols the TPM, makes a recovery key, uploads it to the panel with its device token, and only
#   then removes the image key. While the panel can't take the key, the image key stays (never lock
#   the owner out); the service retries on its own, at least every 2 minutes.
# - Later boots unlock through the TPM alone.
# - "lock" logs everyone out and blocks every login but root until "unlock"; it survives a reboot;
#   the PC reports `locked` (true/false) on every check-in.
# - "wipe" is refused unless the PC is built with codered.fleet.agent.allowWipe AND is locked. When it
#   runs it reports "done" first, then destroys every LUKS keyslot and powers off.
# Run: nix build .#checks.x86_64-linux.encryption -L
{
  self,
  pkgs,
}: let
  imageKey = pkgs.writeText "fleet-image-key" "fleet-image-key-not-secret";
  mock = dir: "${pkgs.python3}/bin/python3 ${./mock_panel_security.py} 8080 ${dir}";
in
  pkgs.testers.runNixOSTest {
    name = "encryption";

    nodes.machine = {
      lib,
      pkgs,
      ...
    }: {
      imports = [self.nixosModules.agent self.nixosModules.encryption];

      virtualisation = {
        emptyDiskImages = [2048];
        useBootLoader = true;
        useEFIBoot = true;
        mountHostNixStore = true;
        efi.OVMF = pkgs.OVMFFull;
        tpm.enable = true;
        memorySize = 2048;
      };
      boot.loader.systemd-boot.enable = true;
      environment.systemPackages = [pkgs.cryptsetup];

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
        serviceConfig.ExecStart = mock "/mock-panel";
      };

      specialisation.encrypted.configuration = {
        config,
        lib,
        ...
      }: {
        codered.fleet.encryption = {
          enable = true;
          device = "/dev/vdb";
          imageKeyFile = imageKey;
        };
        codered.fleet.agent.allowWipe = true;
        # The VM framework force-empties boot.initrd.luks.devices: re-apply exactly what the module asks for.
        boot.initrd.luks.devices = lib.mkVMOverride {cryptroot = config.codered.fleet.encryption.initrdLuksDevice;};
        virtualisation.rootDevice = "/dev/mapper/cryptroot";
        # Test only: the plain disk stays mounted so the stand-in panel's records survive a wipe.
        virtualisation.fileSystems."/plain" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };
        systemd.services.mock-panel = {
          unitConfig.RequiresMountsFor = "/plain";
          serviceConfig.ExecStart = lib.mkForce (mock "/plain/mock-panel");
        };
      };
    };

    testScript = {nodes, ...}: let
      encrypted = nodes.machine.specialisation.encrypted.configuration.system.build.toplevel;
    in ''
      import json, shlex

      IMAGE_KEY = "${imageKey}"
      BASE, ENC = "/mock-panel", "/plain/mock-panel"

      def reports(d):
          return int(machine.succeed(f"ls {d} | grep -c '^report-' || true").strip() or 0)

      def all_reports(d):
          return [json.loads(machine.succeed(f"cat {d}/report-{i}.json")) for i in range(1, reports(d) + 1)]

      def results(d, action_id):
          return [x for r in all_reports(d) for x in (r.get("action_results") or []) if x.get("id") == action_id]

      def queue(d, actions):
          machine.succeed(f"echo {shlex.quote(json.dumps(actions))} > {d}/queue.json")

      def checkin(d):
          before = reports(d)
          machine.succeed("systemctl start fleet-agent.service")
          machine.wait_until_succeeds(f"test $(ls {d} | grep -c '^report-') -gt {before}")

      vt = [1]

      def try_login(user, password):
          # A fresh VT per attempt, so "Password: " on screen proves the username was really typed.
          vt[0] += 1
          n = vt[0]
          machine.send_key(f"alt-f{n}")
          machine.wait_until_succeeds(f"[ $(fgconsole) = {n} ]")
          machine.wait_for_unit(f"getty@tty{n}.service")
          machine.wait_until_tty_matches(str(n), "login: ")
          machine.send_chars(f"{user}\n")
          machine.wait_until_tty_matches(str(n), "Password: ")
          machine.send_chars(f"{password}\n")
          machine.sleep(8)
          return machine.execute(f"loginctl list-sessions --no-legend | grep -q {user}")[0] == 0

      def recovery_opens(key):
          return machine.execute(f"printf %s {shlex.quote(key)} | cryptsetup open --test-passphrase --key-file=- /dev/vdb")[0] == 0

      def image_key_opens():
          return machine.execute(f"cryptsetup open --test-passphrase --key-file={IMAGE_KEY} /dev/vdb")[0] == 0

      def digests():
          return machine.succeed("cryptsetup luksDump /dev/vdb | sed -n '/^Digests:/,$p'")

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("mock-panel.service")
      machine.wait_for_open_port(8080)

      with subtest("the disk arrives encrypted with the image's shared, temporary key"):
          machine.succeed(f"cryptsetup luksFormat -q --type luks2 --iter-time=1 --key-file={IMAGE_KEY} /dev/vdb")
          machine.succeed(f"cryptsetup open --key-file={IMAGE_KEY} /dev/vdb cryptroot")
          machine.succeed("mkfs.ext4 -q /dev/mapper/cryptroot && cryptsetup close cryptroot")
          image_digests = digests()

      with subtest("a PC not built to allow wiping refuses a wipe"):
          checkin(BASE)
          queue(BASE, [{"id": "w0", "type": "wipe", "force": False}])
          checkin(BASE)
          checkin(BASE)
          assert any(x["status"] == "failed" for x in results(BASE, "w0")), results(BASE, "w0")
          assert image_key_opens()

      with subtest("first boot from the image unlocks with the image key, no password"):
          machine.succeed(f"touch {BASE}/escrow-down")
          machine.succeed("${encrypted}/bin/switch-to-configuration boot")
          machine.succeed("bootctl set-default nixos-generation-1-specialisation-encrypted.conf")  # test only: boot the image's config
          machine.succeed("sync")
          machine.crash()
          machine.wait_for_unit("multi-user.target")
          assert "/dev/mapper/cryptroot on / type ext4" in machine.succeed("mount")

      with subtest("while the panel can't take the recovery key, the image key keeps working"):
          machine.wait_until_succeeds(f"test -s {ENC}/escrow-attempts", timeout=900)
          assert image_key_opens()
          machine.fail(f"test -e {ENC}/escrow.json")

      with subtest("panel back: new volume key, TPM enrolled, recovery key escrowed, image key gone"):
          machine.succeed(f"rm {ENC}/escrow-down")
          machine.wait_until_succeeds(f"test -s {ENC}/escrow.json", timeout=900)
          machine.wait_until_succeeds(f"! cryptsetup open --test-passphrase --key-file={IMAGE_KEY} /dev/vdb", timeout=900)
          machine.wait_until_succeeds("! cryptsetup luksDump /dev/vdb | grep -qi reencrypt", timeout=900)
          assert digests() != image_digests, "the volume key must be replaced: every PC from one image shared it"
          assert machine.succeed(f"cat {ENC}/escrow.auth").strip() == "Bearer dev-token-123"
          esc = json.loads(machine.succeed(f"cat {ENC}/escrow.json"))
          assert esc["luks_uuid"] == machine.succeed("cryptsetup luksUUID /dev/vdb").strip(), esc
          key = esc["recovery_key"]
          assert recovery_opens(key), "the escrowed recovery key must open the disk"
          assert "systemd-tpm2" in machine.succeed("cryptsetup luksDump /dev/vdb")

      with subtest("later boots unlock through the TPM alone"):
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          assert "/dev/mapper/cryptroot on / type ext4" in machine.succeed("mount")
          machine.fail("systemctl is-failed --quiet fleet-encryption.service")
          machine.wait_for_unit("mock-panel.service")
          machine.wait_for_open_port(8080)

      with subtest("lock logs everyone out, blocks logins, and survives a reboot"):
          checkin(ENC)
          assert try_login("alice", "alice"), "alice can log in before the lock"
          queue(ENC, [{"id": "l1", "type": "lock", "force": False}])
          checkin(ENC)
          checkin(ENC)
          assert any(x["status"] == "done" for x in results(ENC, "l1")), results(ENC, "l1")
          machine.wait_until_fails("loginctl list-sessions --no-legend | grep -q alice", timeout=60)
          assert all_reports(ENC)[-1].get("locked") is True, all_reports(ENC)[-1]
          assert not try_login("alice", "alice"), "a locked PC must refuse logins"
          machine.shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          machine.wait_for_unit("mock-panel.service")
          machine.wait_for_open_port(8080)
          checkin(ENC)
          assert all_reports(ENC)[-1].get("locked") is True, "still locked after a reboot"
          assert not try_login("alice", "alice"), "still refusing logins after a reboot"

      with subtest("unlock lets people log in again"):
          queue(ENC, [{"id": "u1", "type": "unlock", "force": False}])
          checkin(ENC)
          checkin(ENC)
          assert any(x["status"] == "done" for x in results(ENC, "u1")), results(ENC, "u1")
          assert all_reports(ENC)[-1].get("locked") is False, all_reports(ENC)[-1]
          assert try_login("alice", "alice")

      with subtest("wipe is refused while the PC is not locked"):
          queue(ENC, [{"id": "w1", "type": "wipe", "force": False}])
          checkin(ENC)
          checkin(ENC)
          assert any(x["status"] == "failed" for x in results(ENC, "w1")), results(ENC, "w1")
          assert recovery_opens(key)

      with subtest("wipe on a locked PC: reported, then every disk key destroyed, then power off"):
          machine.succeed("bootctl set-default nixos-generation-1.conf")  # test only: come back on the plain disk
          queue(ENC, [{"id": "l2", "type": "lock", "force": False}])
          checkin(ENC)
          checkin(ENC)
          assert all_reports(ENC)[-1].get("locked") is True
          queue(ENC, [{"id": "w2", "type": "wipe", "force": False}])
          machine.execute("systemctl start --no-block fleet-agent.service")
          machine.wait_for_shutdown()
          machine.start()
          machine.wait_for_unit("multi-user.target")
          assert "/dev/mapper/cryptroot" not in machine.succeed("mount")
          assert any(x["status"] == "done" for x in results(BASE, "w2")), results(BASE, "w2")
          assert not recovery_opens(key), "after a wipe the recovery key must not open the disk"
          assert not image_key_opens()
          machine.fail("cryptsetup luksDump /dev/vdb | grep -qE '^ +[0-9]+: luks2'")
    '';
  }

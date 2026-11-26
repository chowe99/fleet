# LOCKED acceptance test: do not edit, weaken, skip or delete.
# The unattended installer (README "Install PCs").
# - `self.lib.mkInstaller { target = <a group from mkFleet>; modules = [...]; }` is a NixOS system whose
#   `config.system.build.installerImage` holds `fleet-installer.raw`: a UEFI-bootable disk image a technician
#   writes to a USB stick. It carries everything to install the group offline.
# - Its job comes from `fleet/install.json` ({"enroll_token": ..., "hostname": optional, "disk": optional}),
#   dropped onto the stick's FAT partition by the technician, or staged on the PC's own EFI system partition
#   by the Windows migration script. Nobody touches the keyboard.
# - Before it touches any disk it must have: an install.json; the panel (the group's agent URL) reachable and
#   accepting the enrol token; exactly one internal disk to install on (or the one install.json names). Without
#   any of those it leaves every disk exactly as it was and restarts or powers off by itself, so a PC staged
#   from Windows comes back as Windows. A refusal the panel can act on (which disk?) is reported as `failed`
#   with the reason. It never installs onto a USB stick or the medium it booted from, and never over a PC that
#   already runs Fleet.
# - It tells the panel `installing` (POST /api/v1/migration-status, the PC's serial, Bearer <enrol token>)
#   before it wipes. The panel answers 404 for a PC it has no Windows inventory of; that must not stop it.
# - The installed PC then starts with no stick, no keyboard and no password: it unlocks its disk with the image
#   key, takes its hostname from install.json, enrols with the token, and escrows its recovery key (TPM).
# tests/fixtures/install-helpers.py builds the disks and QEMU command lines and may be edited for mechanics only.
# Run: nix build .#checks.x86_64-linux.installer -L
{
  self,
  pkgs,
}: let
  inherit (pkgs) lib;
  token = "enroll-install-7f3a";
  target =
    (self.lib.mkFleet {
      groups.office = {
        profile = "desktop";
        modules = [
          {
            codered.fleet.encryption.enable = true;
            codered.fleet.agent = {
              enable = true;
              url = "http://10.0.2.2:8080"; # the test host, through QEMU user networking
              enrollTokenFile = "/var/lib/fleet-agent/enroll-token";
            };
          }
        ];
      };
    }).office;
  installer = self.lib.mkInstaller {
    inherit target;
    modules = [{codered.fleet.installer.panelWait = "30s";}];
  };
in
  pkgs.testers.runNixOSTest {
    name = "installer";
    nodes = {};
    globalTimeout = 7200;

    testScript = ''
      import json, os, re, socket, subprocess, time

      os.environ["PATH"] = "${lib.makeBinPath (with pkgs; [util-linux dosfstools mtools e2fsprogs coreutils cryptsetup qemu_kvm swtpm])}:" + os.environ["PATH"]
      OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
      OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"

      ${builtins.readFile ./fixtures/install-helpers.py}

      IMAGE = "${installer.config.system.build.installerImage}/fleet-installer.raw"
      TOKEN = "${token}"
      SERIAL = "FLEET-SN-0001"
      GOOD = {"enroll_token": TOKEN, "hostname": "office-07"}
      PANEL_DIR = os.path.join(WORK, "panel")
      STICK = os.path.join(WORK, "stick.raw")
      panel = [None]

      def panel_up():
          if panel[0] is None:
              panel[0] = subprocess.Popen(["${pkgs.python3}/bin/python3", "${./mock_panel_install.py}", "8080", PANEL_DIR, TOKEN])
              for _ in range(100):
                  try:
                      socket.create_connection(("127.0.0.1", 8080), timeout=1).close()
                      return
                  except OSError:
                      time.sleep(0.1)
              raise Exception("mock panel did not start")

      def panel_down():
          if panel[0] is not None:
              panel[0].kill()
              panel[0].wait()
              panel[0] = None

      def requests():
          p = os.path.join(PANEL_DIR, "requests.jsonl")
          return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []

      def statuses(reqs, status):
          return [r for r in reqs if r["path"] == "/api/v1/migration-status" and (r["body"] or {}).get("status") == status]

      def boot(machine_name, pc, **kw):
          m = create_machine(pc_command(pc, **kw), name=machine_name)
          m.start()
          return m

      with subtest("no install.json anywhere: every disk left as it was, the PC restarts by itself"):
          panel_up()
          installer_stick(IMAGE, STICK, config=None)
          win = windows_disk(os.path.join(WORK, "pc1.raw"))
          before, n = digest(win), len(requests())
          wait_gone(boot("noconfig", "pc1", internal=[win], usb=[STICK]), 600)
          assert digest(win) == before, "the Windows disk must be untouched"
          assert statuses(requests()[n:], "installing") == []

      with subtest("panel unreachable (install.json staged on the PC's own EFI partition): disk untouched, restarts"):
          panel_down()
          installer_stick(IMAGE, STICK, config=None)
          win = windows_disk(os.path.join(WORK, "pc2.raw"), config=GOOD)
          before = digest(win)
          wait_gone(boot("nopanel", "pc2", internal=[win], usb=[STICK]), 600)
          assert digest(win) == before, "the Windows disk must be untouched"

      with subtest("the panel refuses the enrol token: disk untouched, restarts"):
          panel_up()
          installer_stick(IMAGE, STICK, config={"enroll_token": "enroll-wrong", "hostname": "office-07"})
          win = windows_disk(os.path.join(WORK, "pc3.raw"))
          before, n = digest(win), len(requests())
          wait_gone(boot("badtoken", "pc3", internal=[win], usb=[STICK]), 600)
          assert digest(win) == before, "the Windows disk must be untouched"
          asked = [r for r in requests()[n:] if r["auth"] == "Bearer enroll-wrong" or (r["body"] or {}).get("enroll_token") == "enroll-wrong"]
          assert asked, "it must have asked the panel"

      with subtest("two internal disks, install.json names neither: the panel is told why, both untouched"):
          installer_stick(IMAGE, STICK, config=GOOD)
          win = windows_disk(os.path.join(WORK, "pc4.raw"))
          second = blank_disk(os.path.join(WORK, "pc4-second.raw"))
          b1, b2, n = digest(win), digest(second), len(requests())
          wait_gone(boot("twodisks", "pc4", internal=[win, second], usb=[STICK], serial="FLEET-SN-0004"), 600)
          assert digest(win) == b1 and digest(second) == b2, "neither disk may be touched"
          reqs = requests()[n:]
          failed = statuses(reqs, "failed")
          assert failed, reqs
          assert failed[-1]["auth"] == f"Bearer {TOKEN}", failed[-1]
          assert failed[-1]["body"].get("serial") == "FLEET-SN-0004", failed[-1]
          assert "disk" in failed[-1]["body"].get("detail", "").lower(), failed[-1]
          assert statuses(reqs, "installing") == []

      office = os.path.join(WORK, "office.raw")
      with subtest("install from the stick over Windows: the panel hears `installing`, then the PC restarts"):
          installer_stick(IMAGE, STICK, config=GOOD)
          windows_disk(office)
          before, n = digest(office), len(requests())
          wait_gone(boot("install", "office", internal=[office], usb=[STICK]), 2400)
          reqs = requests()[n:]
          installing = statuses(reqs, "installing")
          assert installing, reqs
          assert installing[0]["auth"] == f"Bearer {TOKEN}", installing[0]
          assert installing[0]["body"].get("serial") == SERIAL, installing[0]
          assert statuses(reqs, "failed") == [], statuses(reqs, "failed")
          assert digest(office) != before, "Windows must be gone"

      with subtest("the installed PC starts alone: no password, its hostname, enrols, escrows its recovery key"):
          escrow = os.path.join(PANEL_DIR, "escrow.json")
          if os.path.exists(escrow):
              os.remove(escrow)
          tpm, sock = start_swtpm("office")
          n = len(requests())
          m = boot("installed", "office", internal=[office], tpm_sock=sock)
          deadline = time.time() + 2400
          while not os.path.exists(escrow):
              assert m.process.poll() is None, "the installed PC stopped instead of finishing its first boot"
              assert time.time() < deadline, ("no recovery key escrowed", requests()[n:])
              time.sleep(5)
          reqs = requests()[n:]
          enrols = [r for r in reqs if r["path"] == "/api/v1/enroll"]
          assert enrols, reqs
          e = enrols[0]["body"]
          assert e.get("enroll_token") == TOKEN and e.get("hostname") == "office-07" and e.get("serial") == SERIAL, e
          esc = json.load(open(escrow))
          key = esc.get("recovery_key", "")
          assert re.fullmatch(r"[cbdefghijklnrtuv]{8}(-[cbdefghijklnrtuv]{8}){7}", key), esc
          reports = [r for r in requests()[n:] if r["path"] == "/api/v1/report"]
          assert reports and reports[-1]["body"].get("hostname") == "office-07", reports[-1:]
          time.sleep(60)
          m.send_monitor_command("system_powerdown")
          wait_gone(m, 300)
          tpm.kill()
          assert recovery_opens(office, key), "the escrowed recovery key must open the installed disk"

      with subtest("the stick left in and booted again: a PC that runs Fleet is not reinstalled"):
          installer_stick(IMAGE, STICK, config=GOOD)
          before, n = digest(office), len(requests())
          wait_gone(boot("again", "office", internal=[office], usb=[STICK]), 600)
          assert digest(office) == before, "the Fleet PC must be left as it was"
          assert statuses(requests()[n:], "installing") == []

      panel_down()
    '';
  }

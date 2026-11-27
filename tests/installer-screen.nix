# LOCKED acceptance test: do not edit, weaken, skip or delete.
# The installers talk to whoever is at the PC on its screen, not only on the serial line (README "Install PCs").
# Found in the Windows migration demo (2026-11-27): after the network installer's stage 1, the screen froze at
# "starting systemd..." while the installer's messages went only to the serial console, so a technician at the PC
# sees nothing for the whole install.
# Each case boots a PC with no fleet/install.json anywhere, so the installer refuses a few seconds into its own
# system. Its "NOT INSTALLING" banner, the same console output as the INSTALLING banner and the progress, must be
# readable on the PC's screen (OCR of the QEMU display), not only on the serial line.
# tests/fixtures/install-helpers.py may be edited for VM mechanics only.
# Run: nix build .#checks.x86_64-linux.installer-screen -L
{
  self,
  pkgs,
}: let
  inherit (pkgs) lib;
  target =
    (self.lib.mkFleet {
      groups.office = {
        profile = "desktop";
        modules = [
          {
            codered.fleet.encryption.enable = true;
            codered.fleet.agent = {
              enable = true;
              url = "http://10.0.2.2:8080";
              enrollTokenFile = "/var/lib/fleet-agent/enroll-token";
            };
          }
        ];
      };
    }).office;
  installer = self.lib.mkInstaller {
    inherit target;
    modules = [
      {
        codered.fleet.installer.net = {
          url = "http://10.0.2.2:8081";
          cachePublicKey = lib.fileContents ./fixtures/cache-test.pub;
        };
      }
    ];
  };
  net = installer.config.system.build.netInstaller;
in
  pkgs.testers.runNixOSTest {
    name = "installer-screen";
    nodes = {};
    enableOCR = true;
    globalTimeout = 3600;

    testScript = ''
      import os, socket  # json, re, shutil, subprocess, time come with the fixture below

      os.environ["PATH"] = "${lib.makeBinPath (with pkgs; [util-linux dosfstools mtools e2fsprogs coreutils qemu_kvm python3Packages.virt-firmware])}:" + os.environ["PATH"]
      OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
      OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"

      ${builtins.readFile ./fixtures/install-helpers.py}

      IMAGE = "${installer.config.system.build.installerImage}/fleet-installer.raw"
      NET = "${net}"

      def refusal_on_screen(machine, label):
          """The banner must be read off the screen before the PC restarts (it shows for 30 s)."""
          seen, deadline = "", time.time() + 600
          while time.time() < deadline and machine.process.poll() is None:
              try:
                  seen = machine.get_screen_text()
              except Exception:
                  break  # the PC restarted meanwhile
              if re.search(r"NOT\s*INSTALLING", seen):
                  wait_gone(machine, 300)
                  return
              time.sleep(1)
          kill(machine)
          raise Exception(f"{label}: 'NOT INSTALLING' was never readable on the screen; last OCR read: {seen[-600:]!r}")

      def net_pc(name):
          disk = windows_disk(os.path.join(WORK, f"{name}.raw"))
          with open(os.path.join(NET, "installer.efi"), "rb") as fh:
              fat_put(f"{disk}@@{esp_offset(disk)}", "EFI/fleet/installer.efi", fh.read())
          boot_next_file(name, disk, "\\EFI\\fleet\\installer.efi")
          m = create_machine(pc_command(name, internal=[disk]), name=name)
          m.start()
          return m

      # Calibration: the network installer's stage 1 refusal (nothing published at net.url) is known to reach the
      # screen, so OCR must read it; otherwise this test cannot tell anything.
      with subtest("calibration: stage 1's refusal is read off the screen"):
          refusal_on_screen(net_pc("stage1pc"), "stage 1")

      with subtest("USB installer: its refusal is on the PC's screen"):
          stick = installer_stick(IMAGE, os.path.join(WORK, "stick.raw"), config=None)
          disk = windows_disk(os.path.join(WORK, "usb-pc.raw"))
          m = create_machine(pc_command("usbpc", internal=[disk], usb=[stick]), name="usbpc")
          m.start()
          refusal_on_screen(m, "USB installer")

      site = subprocess.Popen(["${pkgs.python3}/bin/python3", "-m", "http.server", "8081", "--bind", "127.0.0.1", "--directory", os.path.join(NET, "www")])
      for _ in range(100):
          try:
              socket.create_connection(("127.0.0.1", 8081), timeout=1).close()
              break
          except OSError:
              time.sleep(0.1)

      with subtest("network installer, booted once from the PC's own EFI partition: its refusal is on the screen"):
          refusal_on_screen(net_pc("netpc"), "network installer")

      site.kill()
    '';
  }

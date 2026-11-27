# LOCKED acceptance test: do not edit, weaken, skip or delete.
# The network installer (README "Install PCs"): what the Windows migration script boots.
# - `self.lib.mkInstaller` with `codered.fleet.installer.net = { url; cachePublicKey; cacheUrl ? "<url>/cache"; }`
#   also builds `config.system.build.netInstaller`, a directory holding:
#     installer.efi  at most 48 MiB, so it fits beside Windows on a 100 MB EFI partition;
#     www/           the files to publish at `net.url`.
# - The migration script (fleet-panel scripts/windows/fleet-migrate.ps1) copies installer.efi to \EFI\fleet\installer.efi
#   on the PC's own EFI partition, puts fleet/install.json beside it, and makes it the next boot only (BootNext).
# - installer.efi then runs from RAM. It fetches whatever else it needs from `net.url`, checked against hashes built
#   into installer.efi. It takes the group's system from the binary cache at `net.cacheUrl`, accepted only when
#   signed by `cachePublicKey`. It installs onto the internal disk it started from.
# - Everything the USB installer guarantees still holds (tests/installer.nix). In addition, before it touches any
#   disk it must have fetched and verified its own files, and found the group's system in the cache, signed. If it
#   can't use the cache, it reports `failed` to the panel with "cache" in the detail (a refusal the panel can act on).
#   Every refusal leaves every disk as it was and restarts. The one-time boot is then used up and it sets no new
#   one, so the PC comes back as Windows.
# tests/fixtures/install-helpers.py builds the disks and QEMU command lines and may be edited for mechanics only
# (a PC keeps at most 4096 MB of RAM). tests/fixtures/cache-test.sec is a test-only signing key.
# Run: nix build .#checks.x86_64-linux.net-installer -L
{
  self,
  pkgs,
}: let
  inherit (pkgs) lib;
  token = "enroll-net-91d2";
  cachePublicKey = lib.fileContents ./fixtures/cache-test.pub;
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
    modules = [
      {
        codered.fleet.installer.panelWait = "30s";
        codered.fleet.installer.net = {
          url = "http://10.0.2.2:8081";
          inherit cachePublicKey;
        };
      }
    ];
  };
  net = installer.config.system.build.netInstaller;
  toplevel = target.config.system.build.toplevel;
  # The group's system in a binary cache, signed with the test key: what the operator publishes at net.cacheUrl.
  unsigned = pkgs.mkBinaryCache {
    rootPaths = [toplevel];
    compression = "zstd";
  };
  cache = pkgs.runCommand "fleet-test-cache" {nativeBuildInputs = [pkgs.nix];} ''
    mkdir $out
    cp ${unsigned}/*.narinfo ${unsigned}/nix-cache-info $out/
    chmod u+w $out/*
    ln -s ${unsigned}/nar $out/nar
    mkdir $out/realisations $out/log $out/debuginfo $out/build-trace-v2
    export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/state NIX_CONF_DIR=$TMPDIR
    nix --extra-experimental-features nix-command store sign --store file://$out \
      --key-file ${./fixtures/cache-test.sec} --recursive ${toplevel}
  '';
in
  pkgs.testers.runNixOSTest {
    name = "net-installer";
    nodes = {};
    globalTimeout = 7200;

    testScript = ''
      import os, socket  # json, re, shutil, subprocess, time come with the fixture below

      os.environ["PATH"] = "${lib.makeBinPath (with pkgs; [util-linux dosfstools mtools e2fsprogs coreutils cryptsetup qemu_kvm swtpm python3Packages.virt-firmware])}:" + os.environ["PATH"]
      OVMF_CODE = "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
      OVMF_VARS = "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"

      ${builtins.readFile ./fixtures/install-helpers.py}

      NET = "${net}"
      EFI = os.path.join(NET, "installer.efi")
      WWW = os.path.join(NET, "www")
      CACHE = "${cache}"
      TOKEN = "${token}"
      SERIAL = "FLEET-SN-0001"
      GOOD = {"enroll_token": TOKEN, "hostname": "office-07"}
      PANEL_DIR = os.path.join(WORK, "panel")
      SITE = os.path.join(WORK, "site")  # what the web server at net.url serves
      servers = {}

      def up(name, argv, port):
          if name not in servers:
              servers[name] = subprocess.Popen(argv)
              for _ in range(100):
                  try:
                      socket.create_connection(("127.0.0.1", port), timeout=1).close()
                      return
                  except OSError:
                      time.sleep(0.1)
              raise Exception(f"{name} did not start")

      def panel_up():
          up("panel", ["${pkgs.python3}/bin/python3", "${./mock_panel_install.py}", "8080", PANEL_DIR, TOKEN], 8080)

      def site(www, cache):
          """Publishes `www` at net.url and `cache` at net.url/cache (either may be None: nothing there)."""
          shutil.rmtree(SITE, ignore_errors=True)
          os.makedirs(SITE)
          if www:
              for f in os.listdir(www):
                  os.symlink(os.path.join(www, f), os.path.join(SITE, f))
          if cache:
              os.symlink(cache, os.path.join(SITE, "cache"))
          up("site", ["${pkgs.python3}/bin/python3", "-m", "http.server", "8081", "--bind", "127.0.0.1", "--directory", SITE], 8081)

      def requests():
          p = os.path.join(PANEL_DIR, "requests.jsonl")
          return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []

      def statuses(reqs, status):
          return [r for r in reqs if r["path"] == "/api/v1/migration-status" and (r["body"] or {}).get("status") == status]

      def boot(machine_name, pc, **kw):
          m = create_machine(pc_command(pc, **kw), name=machine_name)
          m.start()
          return m

      def migrating_pc(pc):
          """A Windows PC the migration script has just staged."""
          disk = windows_disk(os.path.join(WORK, f"{pc}.raw"))
          stage_like_migration(pc, disk, EFI, GOOD)
          assert boot_next(pc) is not None
          return disk

      def refused(pc, label):
          disk = migrating_pc(pc)
          before, n = digest(disk), len(requests())
          wait_gone(boot(label, pc, internal=[disk]), 900)
          assert digest(disk) == before, "the Windows disk must be untouched"
          assert boot_next(pc) is None, "a refusal must not leave a one-time boot behind: the PC comes back as Windows"
          reqs = requests()[n:]
          assert statuses(reqs, "installing") == [], reqs
          return reqs

      # A tampered copy of the published files: one byte flipped in the middle of the largest.
      BAD_WWW = os.path.join(WORK, "www-tampered")
      shutil.copytree(WWW, BAD_WWW, symlinks=False)
      big = max((os.path.join(d, f) for d, _, fs in os.walk(BAD_WWW) for f in fs), key=os.path.getsize)
      os.chmod(big, 0o644)
      with open(big, "r+b") as fh:
          fh.seek(os.path.getsize(big) // 2)
          b = fh.read(1)
          fh.seek(-1, 1)
          fh.write(bytes([b[0] ^ 0xFF]))

      # The same cache with every signature removed.
      UNSIGNED = os.path.join(WORK, "cache-unsigned")
      os.makedirs(UNSIGNED)
      for f in os.listdir(CACHE):
          src = os.path.join(CACHE, f)
          if f.endswith(".narinfo"):
              with open(src) as a, open(os.path.join(UNSIGNED, f), "w") as b:
                  b.write("".join(l for l in a if not l.startswith("Sig:")))
          else:
              os.symlink(src, os.path.join(UNSIGNED, f))

      with subtest("installer.efi fits beside Windows on a 100 MB EFI partition"):
          size = os.path.getsize(EFI)
          assert size <= 48 * 2**20, f"installer.efi is {size / 2**20:.1f} MiB"

      panel_up()

      with subtest("nothing published at net.url: the disk untouched, the PC restarts as Windows"):
          site(None, CACHE)
          refused("pc1", "nofiles")

      with subtest("its files tampered with on the way: the disk untouched, the PC restarts as Windows"):
          site(BAD_WWW, CACHE)
          refused("pc2", "tampered")

      with subtest("the cache's system is not signed by the group's key: disk untouched, the panel is told"):
          site(WWW, UNSIGNED)
          reqs = refused("pc3", "unsigned")
          failed = statuses(reqs, "failed")
          assert failed, reqs
          assert failed[-1]["auth"] == f"Bearer {TOKEN}", failed[-1]
          assert failed[-1]["body"].get("serial") == SERIAL, failed[-1]
          assert "cache" in failed[-1]["body"].get("detail", "").lower(), failed[-1]

      office = os.path.join(WORK, "office.raw")
      with subtest("staged by the migration script: the panel hears `installing`, Windows is replaced, it restarts"):
          site(WWW, CACHE)
          windows_disk(office)
          before = digest(office)
          stage_like_migration("office", office, EFI, GOOD)
          n = len(requests())
          wait_gone(boot("install", "office", internal=[office]), 2400)
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
          key = json.load(open(escrow)).get("recovery_key", "")
          assert re.fullmatch(r"[cbdefghijklnrtuv]{8}(-[cbdefghijklnrtuv]{8}){7}", key), key
          time.sleep(60)
          m.send_monitor_command("system_powerdown")
          wait_gone(m, 300)
          tpm.kill()
          assert recovery_opens(office, key), "the escrowed recovery key must open the installed disk"

      for p in servers.values():
          p.kill()
    '';
  }

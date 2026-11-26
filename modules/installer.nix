# The unattended installer (README "Install PCs"): a NixOS system that runs from a USB stick and installs
# one group onto a PC, with nobody at the keyboard. `lib.mkInstaller` builds it; its
# `system.build.installerImage` is the raw disk image to write to the stick:
#
#   partition 1  EFI system partition, FAT32, label FLEET: EFI/BOOT/BOOTX64.EFI (this system as a unified
#                kernel image), fleet/README.txt, and the technician's fleet/install.json
#   partition 2  "fleet-installer-store": a squashfs Nix store with this system and the whole group, so
#                the install needs no network except to reach the panel
#
# The PC runs from RAM (tmpfs root, the squashfs under a tmpfs overlay as /nix/store) and never writes to
# the stick. What it does is in installer.sh.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.codered.fleet.installer;
  inherit (lib) mkOption types;
  target = cfg.target;
  tcfg = target.config;
  agent = tcfg.codered.fleet.agent;
  quote = s: "'${lib.replaceStrings ["'"] ["'\\''"] (toString s)}'";

  # The group's own disko layout (modules/base.nix), aimed at whichever disk the installer picks: it points
  # this path at that disk before formatting.
  targetLink = "/dev/fleet-target";
  formatting =
    (target.extendModules {
      modules = [{disko.devices.disk.main.device = lib.mkForce targetLink;}];
    }).config.system.build;
  partitions = tcfg.disko.devices.disk.main.content.partitions or {};
  espLabel = lib.head (lib.mapAttrsToList (_: p: p.label) (lib.filterAttrs (_: p: p.type == "EF00") partitions) ++ ["disk-main-ESP"]);
  closure = pkgs.closureInfo {rootPaths = [tcfg.system.build.toplevel];};

  # A token file under one of these comes from somewhere at run time (fw_cfg, a secret manager), not the disk.
  runtimeToken = lib.any (p: lib.hasPrefix p agent.enrollTokenFile) ["/sys/" "/proc/" "/dev/" "/run/" "/tmp/"];

  waitMatch = builtins.match "([0-9]+) ?(s|sec|m|min|h)?" cfg.panelWait;
  waitSeconds =
    lib.toInt (lib.elemAt waitMatch 0)
    * {
      s = 1;
      sec = 1;
      m = 60;
      min = 60;
      h = 3600;
    }
    .${
      if lib.elemAt waitMatch 1 == null
      then "s"
      else lib.elemAt waitMatch 1
    };

  installer = pkgs.writeShellApplication {
    name = "fleet-installer";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux
      findutils
      gnugrep
      gnused
      gawk
      jq
      curl
      gptfdisk
      cryptsetup
      efibootmgr
      config.systemd.package
      config.nix.package
      config.system.build.nixos-install
    ];
    text =
      ''
        panel_url=${quote agent.url}
        panel_wait=${toString waitSeconds}
        panel_wait_text=${quote cfg.panelWait}
        group=${quote agent.group}
        target_system=${tcfg.system.build.toplevel}
        disko_format=${formatting.format}/bin/disko-format
        disko_mount=${formatting.mount}/bin/disko-mount
        target_link=${targetLink}
        nar_size_file=${closure}/total-nar-size
        store_paths=${closure}/store-paths
        token_file=${quote agent.enrollTokenFile}
        write_token=${lib.boolToString (!runtimeToken)}
        esp_label=${quote espLabel}
        fixed_hostname=${quote tcfg.networking.hostName}
        refusal_pause=30
        failure_pause=300
      ''
      + builtins.readFile ./installer.sh;
  };

  readme = pkgs.writeText "README.txt" (lib.replaceStrings ["\n"] ["\r\n"] ''
    CodeRed Fleet installer for the "${agent.group}" PCs (panel: ${agent.url})
    ===========================================================================

    This stick replaces everything on a PC's internal disk with ${agent.group}.

    1. Put a file named install.json in this "fleet" folder (see example-install.json):

         {"enroll_token": "<from the panel: Settings > Enrol token>", "hostname": "office-07"}

       "hostname" is optional. "disk" is needed only on a PC with more than one internal disk:
       its name (nvme0n1, sda), /dev path or serial number. In Notepad, save as "All files" so the
       name does not become install.json.txt.
    2. Plug the stick into the PC and start it from the stick (the firmware's boot menu: F12, F11,
       F9 or Esc). No keyboard is needed after that; the PC needs a network cable.
    3. It checks everything before it touches the disk. If it refuses, it shows why on the screen and
       restarts with nothing changed. When it is done it restarts into ${agent.group}.

    It never installs on a USB disk, on this stick, or on a PC that already runs CodeRed Fleet
    (to do that on purpose, add "reinstall": true to install.json).
  '');
  example = pkgs.writeText "example-install.json" (builtins.toJSON {
    enroll_token = "paste the enrol token from the panel here";
    hostname = "office-07";
  });

  # The stick's store: this system and, through it, the whole group, plus the registration nix needs to
  # copy from it. No fragments: nixos-install copies many store paths at once, and small files packed
  # into shared fragment blocks would thrash the kernel's small fragment cache, re-reading each block
  # from the stick for every file.
  storeImage =
    pkgs.runCommand "fleet-installer-store.squashfs" {
      nativeBuildInputs = [pkgs.squashfsTools];
      contents = pkgs.closureInfo {rootPaths = [config.system.build.toplevel];};
      unsafeDiscardReferences.out = true; # self-contained: a file system image, not a store path user
      __structuredAttrs = true;
    } ''
      cp $contents/registration nix-path-registration
      SOURCE_DATE_EPOCH=0 mksquashfs nix-path-registration $(cat $contents/store-paths) $out \
        -no-hardlinks -keep-as-directory -all-root -root-mode 0755 -b 1048576 -no-fragments \
        -comp zstd -Xcompression-level 6 -processors $NIX_BUILD_CORES -quiet
    '';
  uki = "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
  espMiB = 512;
in {
  options.codered.fleet.installer = {
    target = mkOption {
      type = types.raw;
      internal = true;
      description = "The group this stick installs: one `nixosSystem` from `lib.mkFleet`.";
    };
    panelWait = mkOption {
      type = types.strMatching "[0-9]+ ?(s|sec|m|min|h)?";
      default = "5min";
      example = "30s";
      description = ''
        How long the installer keeps trying to reach the panel (the group's agent URL) before it gives up
        and restarts with nothing changed. It covers the network coming up (DHCP) and short panel outages.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = agent.enable;
        message = "lib.mkInstaller: the target group needs codered.fleet.agent (the installer checks the enrol token with its panel).";
      }
      {
        assertion = builtins.attrNames tcfg.disko.devices.disk == ["main"];
        message = "lib.mkInstaller: the target group must use the single `main` disk layout of modules/base.nix.";
      }
    ];

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    system.stateVersion = "26.05";
    networking.hostName = "fleet-installer";

    # Booted as a unified kernel image from the stick's EFI system partition; no boot loader to install.
    boot.loader.grub.enable = false;
    boot.uki.name = "fleet-installer";
    boot.initrd.systemd.enable = true;
    hardware.enableAllHardware = true;
    hardware.enableRedistributableFirmware = true; # network cards
    boot.initrd.availableKernelModules = ["squashfs" "overlay" "usb_storage" "uas" "sd_mod" "xhci_pci" "ehci_pci" "nvme"];
    boot.initrd.kernelModules = ["overlay"];
    boot.kernelParams = [
      "console=ttyS0,115200" # a log for whoever has a serial line
      "console=tty0" # the last one is /dev/console: the screen, where the installer talks
      "quiet"
      "systemd.show_status=error"
      "systemd.gpt_auto=0" # never mount anything by itself
    ];

    fileSystems = {
      "/" = {
        fsType = "tmpfs";
        options = ["mode=0755"];
      };
      "/nix/.ro-store" = {
        device = "/dev/disk/by-partlabel/fleet-installer-store";
        fsType = "squashfs";
        options = ["ro" "threads=multi"];
        neededForBoot = true;
      };
      "/nix/.rw-store" = {
        fsType = "tmpfs";
        options = ["mode=0755"];
        neededForBoot = true;
      };
      "/nix/store" = {
        overlay = {
          lowerdir = ["/nix/.ro-store"];
          upperdir = "/nix/.rw-store/store";
          workdir = "/nix/.rw-store/work";
        };
        neededForBoot = true;
      };
    };

    networking.useNetworkd = true;
    networking.useDHCP = true;
    systemd.network.wait-online.enable = false; # the installer waits for the panel itself (panelWait)

    # Everything also goes to the serial port, as a log; the screen shows only the installer.
    services.journald.extraConfig = ''
      ForwardToConsole=yes
      TTYPath=/dev/ttyS0
      MaxLevelConsole=info
    '';
    boot.initrd.systemd.contents."/etc/systemd/journald.conf".text = ''
      [Journal]
      ForwardToConsole=yes
      TTYPath=/dev/ttyS0
      MaxLevelConsole=info
    '';
    systemd.services."getty@tty1".enable = false;
    systemd.services."autovt@tty1".enable = false;
    users.users.root.hashedPassword = "!"; # nobody logs in; there is nothing to do by hand
    documentation.enable = false;
    nix.settings.substituters = lib.mkForce [];

    systemd.services.fleet-installer = {
      description = "CodeRed Fleet installer";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target" "network.target" "systemd-udevd.service"];
      environment.SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      # The stick's store, registered so nixos-install can copy the group from it.
      preStart = "${config.nix.package}/bin/nix-store --load-db < /nix/store/nix-path-registration";
      serviceConfig = {
        Type = "exec";
        ExecStart = lib.getExe installer;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        FailureAction = "poweroff";
      };
    };

    system.build.installerImage =
      pkgs.runCommand "fleet-installer-image" {
        nativeBuildInputs = with pkgs; [dosfstools mtools util-linux];
        unsafeDiscardReferences.out = true; # a disk image: the store paths inside it are data
        __structuredAttrs = true;
      } ''
        mkfs.vfat -F 32 -n FLEET -C esp.img ${toString (espMiB * 1024)}
        mmd -i esp.img ::EFI ::EFI/BOOT ::fleet
        mcopy -i esp.img ${uki} ::EFI/BOOT/BOOTX64.EFI
        mcopy -i esp.img ${readme} ::fleet/README.txt
        mcopy -i esp.img ${example} ::fleet/example-install.json

        store=${storeImage}
        storeMiB=$((($(stat -c %s $store) + 1048575) / 1048576))
        mkdir $out
        img=$out/fleet-installer.raw
        truncate -s $((1 + ${toString espMiB} + storeMiB + 1))M $img
        sfdisk --quiet $img <<EOF
        label: gpt
        start=2048, size=${toString (espMiB * 2048)}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="fleet-installer-boot"
        size=$((storeMiB * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="fleet-installer-store"
        EOF
        dd if=esp.img of=$img bs=1M seek=1 conv=notrunc,sparse status=none
        dd if=$store of=$img bs=1M seek=$((1 + ${toString espMiB})) conv=notrunc status=none
      '';
  };
}

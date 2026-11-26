# What makes a group's image installable on common business PCs: UEFI
# systemd-boot, a disko layout and generic hardware support. Used by mkFleet.
{
  config,
  lib,
  ...
}: let
  enc = config.codered.fleet.encryption;
  rootFs = {
    type = "filesystem";
    format = "ext4";
    mountpoint = "/";
  };
in {
  imports = [./hardening.nix ./encryption.nix];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  system.stateVersion = lib.mkDefault "26.05";

  # No hostname in the image: the installer writes /etc/hostname, or DHCP
  # provides one, so every PC in a group shares one closure.
  networking.hostName = lib.mkDefault "";

  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  hardware.enableAllHardware = true;
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;
  hardware.cpu.amd.updateMicrocode = true;
  zramSwap.enable = true;

  nix.gc = {
    automatic = true;
    options = "--delete-older-than 30d";
  };

  # With codered.fleet.encryption on, the root partition is LUKS2 opened by this public image key; each
  # PC replaces it and removes it on first boot (modules/encryption.nix), so it need not be secret.
  codered.fleet.encryption = {
    device = lib.mkDefault "/dev/disk/by-partlabel/disk-main-root"; # disko's label for main/root
    imageKeyFile = lib.mkDefault ./image.key;
  };

  # Installed with `disko-install --flake <repo>#<group> --disk main /dev/sdX`.
  disko.devices.disk.main = {
    type = "disk";
    device = lib.mkDefault "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = ["umask=0077"];
          };
        };
        root = {
          size = "100%";
          content =
            if enc.enable
            then {
              type = "luks";
              name = enc.mapperName;
              # Used only to format and fill the image; the encryption module sets boot.initrd.luks.
              settings.keyFile = "${enc.imageKeyFile}";
              initrdUnlock = false;
              # The image key is public, so its (temporary) keyslot gets the cheapest key derivation.
              extraFormatArgs = ["--type" "luks2" "--pbkdf" "pbkdf2" "--pbkdf-force-iterations" "1000"];
              content = rootFs;
            }
            else rootFs;
        };
      };
    };
  };
}

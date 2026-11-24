# What makes a group's image installable on common business PCs: UEFI
# systemd-boot, a disko layout and generic hardware support. Used by mkFleet.
{lib, ...}: {
  imports = [./hardening.nix];
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
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}

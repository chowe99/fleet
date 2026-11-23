# The locked-down school profile: the desktop, plus what students must not
# change. Kiosk rules in /etc/xdg apply to everyone who logs in to the PC.
{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [./desktop.nix ./agent.nix];

  options.codered.fleet.school.allowUsbStorage = lib.mkEnableOption "USB mass storage (blocked by default)";

  config = {
    codered.fleet.agent.profile = "school";

    # Only admins (wheel) may sudo or talk to the nix daemon.
    security.sudo.execWheelOnly = true;
    nix.settings.allowed-users = ["root" "@wheel"];

    # `install` rather than a blacklist, which an explicit modprobe ignores.
    boot.extraModprobeConfig = lib.mkIf (!config.codered.fleet.school.allowUsbStorage) ''
      install usb_storage ${pkgs.coreutils}/bin/false
      install uas ${pkgs.coreutils}/bin/false
    '';

    # No app store: Discover comes with fwupd/flatpak, so drop it explicitly.
    environment.plasma6.excludePackages = [pkgs.kdePackages.discover];
    services.flatpak.enable = false;

    programs.firefox.policies = {
      BlockAboutConfig = true;
      DisablePrivateBrowsing = true;
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DontCheckDefaultBrowser = true;
      ExtensionSettings."*".installation_mode = "blocked";
      Homepage = {
        URL = lib.mkDefault "https://www.school.example/"; # placeholder: set your school's homepage
        StartPage = "homepage";
        Locked = true;
      };
    };

    # KDE Kiosk: widgets, panels and the wallpaper stay as deployed.
    environment.etc."xdg/kdeglobals".text = ''
      [KDE Action Restrictions][$i]
      plasma/plasmashell/unlockedDesktop=false
      plasma/allow_configure_when_locked=false
      ghns=false

      [KDE Control Module Restrictions][$i]
      kcm_wallpaper=false
    '';

    environment.etc."xdg/kscreenlockerrc".text = ''
      [Daemon][$i]
      Autolock=true
      Timeout=10
      LockOnResume=true
    '';
  };
}

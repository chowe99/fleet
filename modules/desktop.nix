# A Windows-style KDE Plasma 6 desktop with LibreOffice, set up system-wide
# (users are generated, so there is no per-user home-manager config).
{
  lib,
  pkgs,
  ...
}: let
  # A Plasma global theme that only adds a layout; everything else falls
  # back to Breeze. Plasma runs the layout on each user's first login.
  layoutId = "codered.fleet.desktop";
  layout = pkgs.runCommand "codered-fleet-layout" {} ''
    dir=$out/share/plasma/look-and-feel/${layoutId}
    install -Dm644 ${./desktop-layout.js} $dir/contents/layouts/org.kde.plasma.desktop-layout.js
    install -Dm644 ${pkgs.writeText "metadata.json" (builtins.toJSON {
      KPackageStructure = "Plasma/LookAndFeel";
      KPlugin = {
        Id = layoutId;
        Name = "CodeRed Fleet";
        Description = "Bottom taskbar, start menu and pinned apps";
      };
    })} $dir/metadata.json
  '';
in {
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  networking.networkmanager.enable = true;
  services.printing.enable = true;

  environment.systemPackages = [
    layout
    pkgs.libreoffice-qt
    pkgs.hunspellDicts.en_AU
  ];
  environment.etc."xdg/kdeglobals".text = ''
    [KDE]
    LookAndFeelPackage=${layoutId}
  '';

  programs.firefox = {
    enable = true;
    preferences = {
      "spellchecker.dictionary_path" = "/run/current-system/sw/share/hunspell";
      "spellchecker.dictionary" = "en-AU";
    };
  };

  # Metric-compatible stand-ins so Office documents keep their layout.
  fonts.packages = [pkgs.liberation_ttf pkgs.carlito pkgs.caladea];

  i18n.defaultLocale = lib.mkDefault "en_AU.UTF-8";
  time.timeZone = lib.mkDefault "Australia/Perth";
}

// Windows-style Plasma layout, applied the first time each user logs in:
// one bottom taskbar with a start menu, pinned apps, tray, clock and a
// show-desktop button.
var apps = ["firefox.desktop", "org.kde.dolphin.desktop", "writer.desktop", "calc.desktop", "impress.desktop"];

var panel = new Panel();
panel.location = "bottom";
panel.height = 2 * Math.ceil((gridUnit * 2.5) / 2);
panel.floating = false;

var menu = panel.addWidget("org.kde.plasma.kickoff");
menu.currentConfigGroup = ["General"];
menu.writeConfig("favorites", apps);
menu.writeConfig("systemApplications", ["systemsettings.desktop", "org.kde.kinfocenter.desktop"]);

var tasks = panel.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", apps.map(function (app) { return "applications:" + app; }));

panel.addWidget("org.kde.plasma.marginsseparator");
panel.addWidget("org.kde.plasma.systemtray");
panel.addWidget("org.kde.plasma.digitalclock");
panel.addWidget("org.kde.plasma.showdesktop");

var desktops = desktopsForActivity(currentActivity());
for (var i = 0; i < desktops.length; i++) {
  desktops[i].wallpaperPlugin = "org.kde.image";
}

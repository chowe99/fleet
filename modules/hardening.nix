# ANSSI GNU/Linux hardening (Securix's modules/anssi, MIT, vendored unmodified in ./anssi).
# `codered.fleet.hardening.level` maps onto `security.anssi`; "off" (default) leaves a PC exactly as before.
# Every rule is either applied or excluded with a reason, recorded on the PC in /etc/fleet/hardening.json
# (built from the module's own resolution logic, so it cannot drift from what is really applied).
{
  config,
  lib,
  ...
}: let
  cfg = config.codered.fleet.hardening;
  anssi = config.security.anssi;
  on = cfg.level != "off";

  num = id: lib.toInt (lib.removePrefix "R" id);
  byNum = a: b: num a < num b;

  report = config.system.build.complianceReport."org.securix.anssi-compliance.v1";
  applied = lib.sort byNum (lib.attrNames (lib.filterAttrs (_: r: r.enable) anssi.rules));
  excluded = lib.mapAttrs (_: e: e.reason) report.exclusions;
in {
  imports = [./anssi];

  options.codered.fleet.hardening.level = lib.mkOption {
    type = lib.types.enum ["off" "minimal" "intermediary" "reinforced"];
    default = "off";
    description = ''
      ANSSI hardening level (French government GNU/Linux guide v2). "off" changes nothing.
      Rules this fleet cannot safely apply are listed as exceptions below and in /etc/fleet/hardening.json.
    '';
  };

  config = lib.mkMerge [
    {
      environment.etc."fleet/hardening.json".text = builtins.toJSON (
        if on
        then {
          inherit (cfg) level;
          inherit applied excluded;
        }
        else {
          level = "off";
          applied = [];
          excluded = {};
        }
      );
    }
    (lib.mkIf on {
      security.anssi = {
        enable = true;
        level = cfg.level;
        category = "client";

        # Each rationale is written for a school IT admin.
        exceptions = {
          R2.rationale = "The module only has a placeholder for this rule: it changes nothing. Set the BIOS/UEFI password and boot order by hand, per PC model.";
          R3.rationale = "Secure Boot needs signed boot files (lanzaboote), which the fleet images do not have yet; the module has no implementation either. Planned.";
          R5.rationale = "Needs Secure Boot first (R3), and the module has no implementation. A boot menu password would also stop unattended update reboots from recovering.";
          R7.rationale = "iommu=force can stop boot on some older boards and breaks some integrated graphics; enable per hardware model only.";
          R8.rationale = "mds=full,nosmt and l1tf=full,force turn off hyper-threading (halves threads on old dual-core PCs); slub_debug/page_poison slow everything. Too costly for lab PCs; the sysctl rules still apply.";
          R10.rationale = "Locking kernel modules after boot would stop USB printers, Wi-Fi dongles, projectors and hot-plugged devices from working.";
          R13.rationale = "Turning IPv6 off also removes ::1 (localhost), which CUPS and some apps and browsers use, and breaks IPv6-only Wi-Fi/DNS64 networks. IPv4-only is not needed on a school LAN; revisit with a firewall policy instead.";
        };
      };
    })
  ];
}

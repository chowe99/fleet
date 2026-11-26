# Test fixture: a real Samba Active Directory domain controller for SCHOOL.TEST, provisioned with
# samba-tool on first start, running the samba AD DC daemon with its own DNS.
# It MAY be edited to make the domain controller work in the VM, but it must stay a genuine Samba AD DC
# (samba-tool domain provision + the `samba` daemon + its internal DNS): never a stub or a plain LDAP server.
{
  config,
  pkgs,
  ...
}: let
  samba = pkgs.sambaFull;
  ip = config.networking.primaryIPAddress;
in {
  networking.firewall.enable = false;
  networking.nameservers = ["127.0.0.1"];
  environment.systemPackages = [samba pkgs.krb5];
  virtualisation.memorySize = 1536;

  systemd.services.samba-ad-dc = {
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    path = [samba];
    preStart = ''
      if [ ! -e /var/lib/samba/private/sam.ldb ]; then
        rm -f /etc/samba/smb.conf
        mkdir -p /etc/samba /var/lib/samba/private
        samba-tool domain provision --realm=SCHOOL.TEST --domain=SCHOOL --server-role=dc \
          --dns-backend=SAMBA_INTERNAL --adminpass='Adm1n-Passw0rd!' --host-ip=${ip} \
          --option="interfaces = lo ${ip}" --option="bind interfaces only = yes"
      fi
    '';
    serviceConfig = {
      ExecStart = "${samba}/bin/samba --foreground --no-process-group";
      TimeoutStartSec = "10min";
    };
  };
}

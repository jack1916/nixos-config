{ lib, ... }: {
  # This file was populated at runtime with the networking
  # details gathered from the active system.
  #
  # Hetzner Cloud uses a /32 IPv4 address with a gateway OUTSIDE that
  # subnet. The gateway route therefore needs prefixLength = 32 to be
  # treated as onlink, otherwise the default route is unusable and the
  # machine boots with no network. DHCP cannot express this.
  networking = {
    nameservers = [ "185.12.64.1" "185.12.64.2" "2a01:4ff:ff00::add:1" "2a01:4ff:ff00::add:2" ];
    defaultGateway = "172.31.1.1";
    defaultGateway6 = {
      address = "fe80::1";
      interface = "eth0";
    };
    dhcpcd.enable = false;
    usePredictableInterfaceNames = lib.mkForce false;
    interfaces = {
      eth0 = {
        ipv4.addresses = [
          { address = "2.31.95.62"; prefixLength = 32; }
        ];
        ipv6.addresses = [
          { address = "2a01:4f8:1c16:1a87::1"; prefixLength = 64; }
        ];
        ipv4.routes = [ { address = "172.31.1.1"; prefixLength = 32; } ];
        ipv6.routes = [ { address = "fe80::1"; prefixLength = 128; } ];
      };
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="92:00:0a:3b:e3:29", NAME="eth0"
  '';
}

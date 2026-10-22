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
    # MUST use the attrs form { address; interface; }, not the bare string
    # `defaultGateway = "172.31.1.1"` that nixos-infect generates.
    # Upstream issue #271: the bare-string form stopped producing a usable
    # default route in 26.05+ (the gateway lost its interface binding), so
    # the host came up with no networking at all. The attrs form works on
    # both 25.11 and 26.11.
    defaultGateway = {
      address = "172.31.1.1";
      interface = "eth0";
    };
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

  # NOTE: a udev rule renaming the NIC by hardcoded MAC address
  # (`ATTR{address}=="92:...", NAME="eth0"`) used to live here and was
  # REMOVED. It was the cause of a total network outage: during a rebuild
  # the udev rule re-fired, the interface did not end up named eth0, and
  # `network-addresses-eth0.service` therefore never applied the /32
  # address or the onlink gateway route, leaving the host unreachable
  # while the console still worked.
  #
  # The rule was never needed: Hetzner KVM/QEMU exposes the NIC as eth0
  # already, and usePredictableInterfaceNames = false (above) keeps that
  # name stable. Do not reintroduce a MAC-based rename rule.
}

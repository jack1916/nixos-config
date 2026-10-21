# WireGuard gateway running on the public VPS.
#
# The VPS owns the static, publicly reachable endpoint. All Plex traffic
# from the homeserver is carried inside this tunnel, so the home carrier
# NAT address is never exposed to external Plex clients.
#
# Tunnel layout:
#   vps        = 10.100.0.1/24  (server / peer with fixed public endpoint)
#   homeserver = 10.100.0.2/24  (client behind carrier NAT)
#
# Forwarded client traffic is handled purely by Caddy's reverse_proxy
# (userspace TCP), so no IP forwarding or NAT rules are needed here.
#
# This module owns the UDP 51820 allow rule: the NixOS WireGuard module
# does not open its listen port on its own.
{
  config,
  ...
}:

let
  homeserverTunnelIp = "10.100.0.2";
in
{
  # Keys/tunnel secrets are NOT committed. Only hashes/paths live in git.
  # The public key below is a placeholder (public keys are not secret);
  # replace it with the value printed by `wg pubkey` on the homeserver.
  sops.secrets."wireguard/vps-private-key" = {
    key = "wireguard_private_key";
    # Default permissions are root:root 0400 — do not loosen these.
  };

  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.100.0.1/24" ];
    listenPort = 51820;
    privateKeyFile = config.sops.secrets."wireguard/vps-private-key".path;

    peers = [
      {
        # homeserver's public key — not a secret, safe to commit.
        publicKey = "J5vPv+WvWJl7ONE+iT2fpwXJhqR20tMKnAqHGxCQfmg=";
        allowedIPs = [ "${homeserverTunnelIp}/32" ];
        # No endpoint and no keepalive here: the homeserver dials in from
        # behind carrier NAT and holds the session open itself.
      }
    ];
  };

  # 1420 avoids fragmentation on the carrier/DSL path (1500 - WG/IPv4/UDP).
  networking.interfaces.wg0.mtu = 1420;

  # The WireGuard module does NOT open its listen port automatically —
  # without this line the handshake from the homeserver never arrives.
  networking.firewall.allowedUDPPorts = [ 51820 ];

  # Accept tunnel traffic (Plex requests arriving over wg0).
  networking.firewall.trustedInterfaces = [ "wg0" ];

  # rpfilter runs in `prerouting`, i.e. BEFORE the wg0 trust/input rules,
  # so strict reverse-path filtering would drop packets whose reply route
  # differs from the ingress interface. "loose" keeps the tunnel working at
  # the cost of strict spoofing protection; forwarding is still disabled.
  networking.firewall.checkReversePath = "loose";

  # Make the tunnel come up before Caddy starts proxying to it, so the
  # first ACME/HTTP request does not hit a dead backend.
  systemd.services.caddy = {
    requires = [ "wireguard-wg0.service" ];
    after = [
      "wireguard-wg0.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
  };
}

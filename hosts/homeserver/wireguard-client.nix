# WireGuard client on the homeserver (behind carrier NAT).
#
# Dials out to the VPS gateway at 2.31.95.62:51820 and keeps the tunnel
# open with persistentKeepalive = 25 — this is what punches/stabilises the
# NAT mapping so the VPS can always reach Plex at 10.100.0.2:32400.
#
# No ports are opened here: the homeserver is never addressed inbound from
# the internet, only through the tunnel originated by this client.
{
  config,
  pkgs,
  ...
}:

let
  vpsEndpoint = "2.31.95.62:51820";
  vpsTunnelIp = "10.100.0.1";
in
{
  # Keys live in sops, never in git. Provision with `sops secrets/homeserver.yaml`.
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.defaultSopsFile = ./../../secrets/homeserver.yaml;
  sops.defaultSopsFormat = "yaml";

  sops.secrets."wireguard/homeserver-private-key" = {
    key = "wireguard_private_key";
    # default: root:root 0400
  };
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.100.0.2/24" ];
    privateKeyFile = config.sops.secrets."wireguard/homeserver-private-key".path;

    peers = [
      {
        # VPS public key — not a secret, safe to commit.
        publicKey = "7F+5XUOB5ZvdlCF2UpeACiEkhWp8J3szGH1K1tVDUEg=";
        # Route ONLY the VPS tunnel address through wg0. Plex traffic never
        # leaves the tunnel directly: the VPS proxies to us over it.
        allowedIPs = [ "${vpsTunnelIp}/32" ];
        endpoint = vpsEndpoint;
        # CRITICAL for carrier NAT: re-send a handshake every 25s when idle
        # so the NAT/port mapping does not expire.
        persistentKeepalive = 25;
      }
    ];

    # Must match the gateway and fit the carrier-NAT path. See the PMTU
    # note in hosts/vps/wireguard.nix: 1420 was too large and caused large
    # transfers to hang while small ones worked.
    mtu = 1380;
  };

  # Allow inbound Plex requests that arrive over the tunnel.
  networking.firewall.trustedInterfaces = [ "wg0" ];

  # Restart the tunnel if it dies, so a dropped tunnel shows up in the
  # journal instead of silently dropping streams.
  #
  # Do NOT add after/wants = [ "network-online.target" ] here. The nixpkgs
  # WireGuard module orders the interface unit with `before = [
  # "network.target" ]` (so wg0 exists before its addresses are assigned),
  # and network-online.target is ordered after network.target. Adding the
  # onlined edge therefore creates the cycle
  #   wg0 -> network.target -> network-online.target -> wg0
  # which systemd resolves by DELETING the interface's start job: wg0 is
  # never created and the tunnel is dead after every boot.
  # wantedBy = multi-user.target is already set by the module.
  systemd.services."wireguard-wg0" = {
    serviceConfig.Restart = "on-failure";
  };

  # Handy diagnostics; `wg` is required anyway for the interface.
  environment.systemPackages = [ pkgs.wireguard-tools ];

  environment.etc."wireguard/homeserver.endpoint".text = ''
    VPS endpoint: ${vpsEndpoint}
    VPS tunnel IP: ${vpsTunnelIp}
    This host's tunnel IP: 10.100.0.2
  '';
}

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

    mtu = 1420;
  };

  # Allow inbound Plex requests that arrive over the tunnel.
  networking.firewall.trustedInterfaces = [ "wg0" ];

  # Verify the tunnel is healthy after boot, and let failures show up in
  # the journal instead of silently dropping streams.
  systemd.services."wireguard-wg0" = {
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
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

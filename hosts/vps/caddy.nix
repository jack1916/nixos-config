# Reverse proxy terminating TLS for Plex.
#
# Caddy obtains and renews a Let's Encrypt certificate for
# plex.9485432.xyz automatically (ACME HTTP-01 on :80, TLS on :443) and
# forwards requests through the WireGuard tunnel to Plex on the
# homeserver at 10.100.0.2:32400.
#
# Plex clients perform a large amount of direct/range traffic, so we:
#   - disable response buffering (flush_interval -1) so streams are not
#     held in memory,
#   - pass through the client's real address,
#   - compress API/XML responses, which is a small win over the tunnel.
#     `encode` leaves already-compressed media alone, so video is not
#     re-encoded.
{
  ...
}:

let
  domain = "plex.9485432.xyz";
  plexUpstream = "http://10.100.0.2:32400";
in
{
  services.caddy = {
    enable = true;
    # Caddy's own log directory; this is a fresh host with plenty of room.
    logDir = "/var/log/caddy";
    email = "jackholsgrove@gmail.com";

    virtualHosts.${domain} = {
      # Caddy listens on 80/443 automatically for a hostname vhost and
      # provisions the certificate with the default ACME CA (Let's
      # Encrypt production). No useACMEHost needed.
      extraConfig = ''
        encode zstd gzip

        # Media streaming: do not buffer large Plex responses in memory.
        reverse_proxy ${plexUpstream} {
          flush_interval -1
          # Plex uses websockets for the web UI / clients.
          header_up X-Forwarded-Host {host}
          header_up X-Real-IP {remote_host}
          header_up X-Forwarded-For {remote_host}
          header_up X-Forwarded-Proto {scheme}
        }

        # Plex's own HTTPS is not used: TLS terminates here on the VPS.
        header {
          -Server
          -X-Powered-By
          X-Frame-Options SAMEORIGIN
          X-Content-Type-Options nosniff
        }

        log {
          output file /var/log/caddy/plex-access.log
          format json
        }
      '';
    };
  };

  # Firewall: 80 (ACME HTTP-01 + redirect), 443 (TLS). 51820/udp is opened
  # in wireguard.nix; SSH (22) in default.nix.
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # ACME stores its state under /var/lib/acme; surfaces already persist on
  # the root disk. Just make sure the Caddy log dir exists with the right
  # ownership before the service starts.
  systemd.tmpfiles.rules = [
    "d /var/log/caddy 0750 caddy caddy -"
  ];

  # Plex streams are long-lived. The module defaults to reloading (not
  # restarting) Caddy on config change, which needs the admin API enabled;
  # a finite grace_period keeps reloads from waiting on active streams.
  services.caddy.globalConfig = ''
    grace_period 30s
  '';
}

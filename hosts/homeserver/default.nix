# Homeserver host entry point.
#
# Media runs on Jellyfin (modules/services/jellyfin.nix) and the
# download/import stack in modules/services/media-utils.nix. This is now
# the ONLY host in the flake. The public VPS gateway and the WireGuard
# tunnel that reached it have both been removed; remote access is to be
# re-done with Tailscale (already enabled below). See AGENTS.md for why.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./../../hardware-configuration.nix
    ./../../modules/services/jellyfin.nix
  ];

  nixpkgs.config.allowUnfree = true;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  hardware.enableAllFirmware = true;

  networking.hostName = "homeserver";
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = true;

  time.timeZone = "Europe/Dublin";

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
  };

  services.adguardhome = {
    enable = true;
    openFirewall = true;
    settings = {
      http.address = "0.0.0.0:3000";
      dns.upstream_dns = [
        "1.1.1.1"
        "8.8.8.8"
      ];
    };
  };

  security.sudo.wheelNeedsPassword = false;

  users.users.jack = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
    ];
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    htop
    gnumake
    powertop
    nordvpn
  ];

  # NordVPN is used manually to keep P2P traffic off the home IP. The CLI
  # talks to a background daemon (nordvpnd), so that needs to be running for
  # `nordvpn login/connect/status` to work.
  #
  # One-time setup after the first rebuild (not declarative - it binds to
  # your NordVPN account):
  #   sudo nordvpn login
  #   sudo nordvpn settings killswitch disabled   # killswitch would cut LAN too
  #   sudo nordvpn whitelist add subnet 192.168.0.0/24
  #   sudo nordvpn whitelist add port 8096        # LAN access to Jellyfin
  #   sudo nordvpn connect
  #
  # Deliberately NOT automated at boot: if a launch-time connect silently
  # fails, other traffic would quietly run over the home IP with no warning.
  # Connect by hand and check `nordvpn status` first.
  #
  # MTU: NordVPN brings nordlynx up at 1420, but the real path MTU on this
  # carrier-NAT link is lower. Measured with `ping -M do`: 1300 passes,
  # 1372 is dropped. At 1420 the symptom is that TCP connects and DNS works
  # but every HTTPS request hangs (curl returns 000 after the full timeout)
  # because the TLS handshake's larger packets are silently dropped. Setting
  # the interface to 1380 (same value the old WireGuard tunnel used) fixes
  # it: HTTP 200 in 35ms. This is the same failure mode as AGENTS.md item 2;
  # do not "fix" it by raising the value.
  systemd.services.nordvpn-mtu = {
    description = "Lower nordlynx MTU to 1380 (path MTU is below NordVPN's 1420)";
    wantedBy = [ "multi-user.target" ];
    # nordlynx only exists once the tunnel is up, so re-run on changes.
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # The tunnel is connected by hand, so nordlynx may not exist yet.
      # Wait up to ~5 min for it, then give up rather than hanging forever.
      for _ in $(${pkgs.coreutils}/bin/seq 1 150); do
        if ${pkgs.iproute2}/bin/ip link show nordlynx >/dev/null 2>&1; then
          ${pkgs.iproute2}/bin/ip link set dev nordlynx mtu 1380
          echo "nordlynx MTU set to 1380"
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 2
      done
      echo "nordlynx did not appear; nothing to do"
    '';
  };

  systemd.services.nordvpnd = {
    description = "NordVPN daemon";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.nordvpn}/bin/nordvpnd";
      Restart = "on-failure";
      RestartSec = 5;
      # nordvpnd manages network interfaces and firewall rules.
      AmbientCapabilities = [
        "CAP_NET_ADMIN"
        "CAP_NET_RAW"
      ];
      NoNewPrivileges = false;
    };
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # NordVPN pushes a full-tunnel route and installs its own nftables rules.
  # Strict reverse-path filtering drops the replies that come back over the
  # tunnel interface, which presents as "connects, then hangs".
  networking.firewall.checkReversePath = "loose";

  system.stateVersion = "25.11";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  services.power-profiles-daemon.enable = true;
  powerManagement.powertop.enable = true;

  # Pull the flake from GitHub rather than a local checkout. Pointing at a
  # local path silently did nothing: flake.lock is pinned, so without a
  # `git pull` the rebuild just reproduced the same closure every night and
  # no security patches ever arrived.
  #
  # The lock advances only via the daily Update Flake Lock workflow, which
  # builds this host before committing. Do NOT add `--update-input nixpkgs`
  # here: that would let this machine resolve its own nixpkgs and bypass
  # that gate.
  system.autoUpgrade = {
    enable = true;
    flake = "github:jack1916/nixos-config#homeserver";
    dates = "03:00";
    # Jitter the fetch so it does not hammer GitHub at exactly 03:00. The
    # VPS used to run at the same time and this stagger kept the two
    # apart; with the VPS gone it just spreads load.
    randomizedDelaySec = "15m";
    # Kernel, glibc and systemd patches need a reboot to take effect.
    # A reboot only happens when the kernel/initrd actually changed, not
    # every night. Jellyfin drops briefly inside the window; that is the
    # trade for actually running patched code.
    allowReboot = true;
    rebootWindow = {
      lower = "03:00";
      upper = "05:00";
    };
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}

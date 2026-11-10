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
    ./../../modules/services/media-utils.nix
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
  # Deliberately NOT automated at boot: transmission is not tied to the VPN,
  # so a launch-time connect can silently fail and leave torrents running
  # over the home IP. Connect by hand and check `nordvpn status` first.
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

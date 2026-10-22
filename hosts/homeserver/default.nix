# Homeserver host entry point.
#
# The existing Plex setup stays untouched in modules/services/plex.nix;
# this file now lives under hosts/homeserver/ so the flake can manage both
# hosts in one repository. WireGuard client config is a separate module
# (./wireguard-client.nix) imported from flake.nix.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./../../hardware-configuration.nix
    ./../../modules/services/plex.nix
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
      dns.upstream_dns = [ "1.1.1.1" "8.8.8.8" ];
    };
  };

  security.sudo.wheelNeedsPassword = false;

  users.users.jack = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" ];
  };

  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    htop
    gnumake
    powertop
  ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  system.stateVersion = "25.11";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  services.power-profiles-daemon.enable = true;
  powerManagement.powertop.enable = true;

  # Pull the flake from GitHub rather than a local checkout. Pointing at a
  # local path silently did nothing: flake.lock is pinned, so without a
  # `git pull` the rebuild just reproduced the same closure every night and
  # no security patches ever arrived.
  #
  # The lock advances only via the daily Update Flake Lock workflow, which
  # builds both hosts before committing. Do NOT add `--update-input nixpkgs`
  # here: that would let this machine resolve its own nixpkgs and bypass
  # that gate.
  system.autoUpgrade = {
    enable = true;
    flake = "github:jack1916/nixos-config#homeserver";
    dates = "03:00";
    # Stagger against the VPS, which also runs at 03:00.
    randomizedDelaySec = "15m";
    # Kernel, glibc and systemd patches need a reboot to take effect.
    # A reboot only happens when the kernel/initrd actually changed, not
    # every night. Plex drops briefly inside the window; that is the trade
    # for actually running patched code.
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

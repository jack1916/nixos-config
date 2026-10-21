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

  system.autoUpgrade = {
    enable = true;
    flake = "/home/jack/nixos-config/";
    dates = "03:00";
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

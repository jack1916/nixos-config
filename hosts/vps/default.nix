# Public VPS gateway for Plex.
#
# Role: hold the static public IP (2.31.95.62), terminate TLS for
# plex.9485432.xyz, and reverse-proxy through a WireGuard tunnel to Plex
# on the homeserver (10.100.0.2:32400). The homeserver is behind carrier
# NAT, so it dials out to this host and its home IP is never exposed.
#
# Installed with nixos-anywhere using hosts/vps/disko.nix; see README.md.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./wireguard.nix
    ./caddy.nix
    inputs.sops-nix.nixosModules.sops
  ];

  # --- Platform ---------------------------------------------------------
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  system.stateVersion = "25.11";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 3;

  # Single-disk VPS: make sure the initrd has virtio/virtio-scsi drivers so
  # the machine boots on any KVM provider.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "ahci"
    "sd_mod"
    "sr_mod"
    "ext4"
  ];
  boot.kernelModules = [ ];

  # --- Basics -----------------------------------------------------------
  networking.hostName = "vps";
  time.timeZone = "Europe/Dublin";

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # Keep the tiny 40GB root disk from filling up with old closures.
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    tcpdump
    wireguard-tools
    dig
  ];

  # --- Access -----------------------------------------------------------
  services.openssh = {
    enable = true;
    # Key-only access; this box is on the open internet.
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # root keeps key-only SSH so nixos-anywhere (which connects as root) and
  # post-install recovery both work. Password login stays disabled.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE+aHyrXiBrZZaJ6kQTwBq8buMW4CGB0YaaLgO0OsxSc jack@arch-laptop-jack"
  ];

  # Emergency admin user.
  users.users.jack = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE+aHyrXiBrZZaJ6kQTwBq8buMW4CGB0YaaLgO0OsxSc jack@arch-laptop-jack"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  # --- Firewall ---------------------------------------------------------
  # Default deny inbound. Explicit allows:
  #   80/443 tcp  -> Caddy (ACME + Plex TLS)   [caddy.nix]
  #   51820 udp   -> WireGuard                 [wireguard.nix]
  #   22 tcp      -> SSH                       [here]
  # Everything else incoming is dropped.
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # No NAT/forwarding: Caddy proxies in userspace, the tunnel is not a
  # routed network for clients.
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = lib.mkDefault 0;
    "net.ipv6.conf.all.forwarding" = lib.mkDefault 0;
  };

  # --- Secrets ----------------------------------------------------------
  # Secrets are deployed via sops-nix. The age key must be present at
  # /var/lib/sops-nix/key.txt on this host (see README for generation).
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.defaultSopsFile = ./../../secrets/vps.yaml;
  sops.defaultSopsFormat = "yaml";

  # --- Unattended upgrades ---------------------------------------------
  # DISABLED by default: the nixos-config remote is private, so this host
  # cannot fetch the flake without a deploy key. Enabling it as-is would
  # fail every night. To turn it on, either:
  #   1. add a read-only deploy key and clone the repo to /etc/nixos-config,
  #      then set flake = "/etc/nixos-config#vps"; or
  #   2. make the repo public and use github:jack1916/nixos-config#vps.
  # Until then, upgrade manually (see hosts/vps/README.md).
  system.autoUpgrade.enable = false;
}

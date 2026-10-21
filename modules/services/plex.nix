{ config, lib, pkgs, ... }:

{
  # Mount the unmounted storage drive (sdb) to /mnt/media
  fileSystems."/mnt/media" = {
    device = "/dev/disk/by-uuid/07dbcd6c-6077-405d-bb98-ff68de989bad";
    fsType = "ext4";
    options = ["nofail"];
  };

  # Enable Plex Media Server service
  services.plex.enable = true;
  services.plex.openFirewall = true;

  # Declaratively grant the plex user READ-ONLY access to the media tree.
  # Plex only needs read on media: the database, metadata and transcode
  # scratch space all live in /var/lib/plex. Write access would only be
  # used by optional features that drop files next to the media (e.g.
  # video preview thumbnails / BIF generation), so the plex user cannot
  # modify or delete the library even if the service is compromised.
  # Applied via systemd-tmpfiles at boot (and idempotently whenever
  # activated). The R prefix is recursive; - stops descending into
  # submounts. The d rule sets a default ACL so new files inherit access.
  # Split into two tmpfiles files because a single file cannot repeat the
  # same rule key ("a+") for the same path.
  systemd.tmpfiles.settings = {
    "10-plex-media-access" = {
      "/mnt/media" = {
        "a+" = { argument = "R u:plex:r-x - - - -"; };
      };
    };
    "11-plex-media-default" = {
      "/mnt/media" = {
        "a+" = { argument = "d:u:plex:r-x - - - -"; };
      };
    };
  };

  # Additional hardening layered on top of the default NixOS plex module.
  systemd.services.plex = {
    # Keep PrivateDevices=false (hardware transcoding needs /dev/dri)
    # but switch to a closed device allowlist: plex gets the GPU render
    # nodes for VAAPI/QSV transcoding and nothing else — no raw disks,
    # no /dev/mem, no block devices.
    serviceConfig = {
      DevicePolicy = "closed";
      DeviceAllow = [
        "char-drm rwm"
        "char-dri rwm"
      ];
      # NOTE: RestrictNamespaces is deliberately NOT set — plex's
      # bundled bubblewrap wrapper creates its own user/mount
      # namespaces to self-sandbox, and fails to start when this is
      # restricted. Same reason ProtectProc/ProcSubset are unset:
      # bwrap needs to read /proc/sys/kernel/*.
      # Only allow the socket families Plex actually needs; the base
      # module already restricts this, keep it explicit.
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
    };
  };
}

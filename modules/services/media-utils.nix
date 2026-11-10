{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Transmission — lightweight, headless-friendly torrent client.
  # Downloads to /mnt/media/torrents/active; completed files are moved to
  # /mnt/media/torrents/complete and then imported by sonarr/radarr into
  # /mnt/media/torrents/TVShows and /mnt/media/torrents/Movies respectively.
  # Web UI on http://homeserver:9091 (LAN only, no auth).
  # The settings block is written to settings.json on first start; changes
  # made via the web UI persist across restarts (they live in the
  # transmission home dir, not in the Nix store).
  services.transmission = {
    enable = true;
    openFirewall = true;
    home = "/var/lib/transmission";
    settings = {
      download-dir = "/mnt/media/torrents/active";
      incomplete-dir = "/mnt/media/torrents/incomplete";
      incomplete-dir-enabled = true;
      rpc-whitelist = "127.0.0.1,192.168.0.*";
      rpc-whitelist-enabled = true;
      rpc-authentication-required = false;
      watch-dir = "/mnt/media/torrents/watch";
      watch-dir-enabled = true;
      # Cap saturation so torrents don't eat the whole uplink (carrier NAT
      # is already tight, and Jellyfin streaming shares the same pipe).
      speed-limit-up-enabled = true;
      speed-limit-up = 500; # KB/s
      speed-limit-down-enabled = true;
      speed-limit-down = 10000; # KB/s (~10 MB/s, reasonable for this HW)
      ratio-limit-enabled = true;
      ratio-limit = 2; # Stop seeding at 2.0 ratio
      seed-queue-size-enabled = true;
      seed-queue-size = 5;
      # Do not preallocate full disk space for every torrent — large ISOs
      # can take minutes and the filesystem isn't swap-bound.
      preallocation = 1; # 0=none, 1=sparse, 2=full
    };
  };

  # Sonarr — TV show management. Monitors shows, searches indexers, sends
  # to Transmission, then imports and renames episodes into the media
  # library. Web UI on http://homeserver:8989.
  services.sonarr = {
    enable = true;
    openFirewall = true;
    group = "transmission";
  };

  # Radarr — movie management (same pattern as Sonarr).
  # Web UI on http://homeserver:7878.
  services.radarr = {
    enable = true;
    openFirewall = true;
    group = "transmission";
  };

  # Prowlarr — indexer proxy. Sonarr & Radarr talk to Prowlarr instead of
  # individual indexers. Web UI on http://homeserver:9696.
  services.prowlarr = {
    enable = true;
    openFirewall = true;
  };

  # ── Media directory layout ─────────────────────────────────────────────
  # The filesystem is mounted in jellyfin.nix; we just ensure the subdirectory
  # structure exists and has the right permissions.
  #
  # IMPORTANT: the library lives UNDER torrents/, not beside it. This is the
  # pre-existing layout on the drive (the collection predates this flake), so
  # the config follows the data rather than creating a parallel empty tree.
  # An earlier version of this file declared /mnt/media/{Movies,TV,Music} and
  # created them empty, which is why Jellyfin appeared to have no media while
  # ~1 TB sat in torrents/. Do not reintroduce those paths.
  #
  #   /mnt/media/torrents/
  #     watch/          ← drop a .torrent here and Transmission picks it up
  #     active/         ← downloading
  #     incomplete/     ← partial (staging)
  #     complete/       ← finished, waiting for sonarr/radarr to import
  #     Movies/         ← radarr library root (Jellyfin: Movies)
  #     TVShows/        ← sonarr library root (Jellyfin: TV)
  #
  # The transmission user (which sonarr/radarr also run as via the group)
  # needs write access. Jellyfin gets read-only via the ACLs in jellyfin.nix.
  #
  # NOTE: these use `systemd.tmpfiles.rules` (raw strings) rather than the
  # structured `settings` option. `settings` runs every value through
  # lib.strings.escapeC, which mangles anything containing a space -- see the
  # long comment in jellyfin.nix. The `d` rules here have no spaces so they
  # would survive, but keeping one style avoids the trap.
  systemd.tmpfiles.rules = [
    "d /mnt/media/torrents 0770 transmission transmission -"
    "d /mnt/media/torrents/watch 0770 transmission transmission -"
    "d /mnt/media/torrents/active 0770 transmission transmission -"
    "d /mnt/media/torrents/incomplete 0770 transmission transmission -"
    "d /mnt/media/torrents/complete 0770 transmission transmission -"
    "d /mnt/media/torrents/Movies 0770 transmission transmission -"
    "d /mnt/media/torrents/TVShows 0770 transmission transmission -"
  ];

  # Transmission failed to start on first boot with
  #   Failed to set up mount namespacing: /mnt/media/torrents/active:
  #   No such file or directory
  # because the tmpfiles rule that creates its download dirs had not run yet.
  # It recovered on the automatic retry, but ordering it explicitly removes
  # the race. The same applies to the arr services, which write into the
  # library roots.
  systemd.services.transmission = {
    after = [
      "mnt-media.mount"
      "systemd-tmpfiles-setup.service"
    ];
    requires = [ "mnt-media.mount" ];
  };
  systemd.services.sonarr = {
    after = [
      "mnt-media.mount"
      "systemd-tmpfiles-setup.service"
    ];
    requires = [ "mnt-media.mount" ];
  };
  systemd.services.radarr = {
    after = [
      "mnt-media.mount"
      "systemd-tmpfiles-setup.service"
    ];
    requires = [ "mnt-media.mount" ];
  };
}

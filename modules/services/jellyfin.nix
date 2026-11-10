# Jellyfin media server.
#
# Owns the /mnt/media mount and grants the jellyfin user read-only access
# to it.
#
# Adding media: copy files in over the LAN with rsync. There is no
# download client or *arr stack any more -- they were removed because their
# indexers are blocked by legal order (HTTP 451), so they could not fetch
# anything. rsync is the whole workflow:
#
#   rsync -av --progress ./Some.Movie.mkv \
#     homeserver:/mnt/media/torrents/Movies/
#
# Layout (pre-existing on the drive, so the config follows the data):
#   /mnt/media/torrents/Movies    ← Jellyfin "Movies" library root
#   /mnt/media/torrents/TVShows   ← Jellyfin "Shows" library root
#
# Files land owned by jack; jellyfin reads them via the ACL below. Jellyfin
# scans on demand (Dashboard → Scan All Libraries) or on its own schedule.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Mount the unmounted storage drive (sdb) to /mnt/media.
  fileSystems."/mnt/media" = {
    device = "/dev/disk/by-uuid/07dbcd6c-6077-405d-bb98-ff68de989bad";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  # Jellyfin — open-source media server. LG WebOS app works well.
  # Web UI on http://homeserver:8096
  #
  # Note: jellyfin does NOT get the openFirewall port forwarded past
  # carrier NAT, so it is LAN-only (plus tailscale0, which the host
  # trusts). Do not add a public reverse proxy without being asked.
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  # Grant jellyfin read-only access to /mnt/media.
  #
  # /mnt/media is drwxr-x--- jack:1000, i.e. other::--- and group::---. That
  # means NOBODY except jack can traverse into it, regardless of what they
  # own underneath -- the kernel checks EVERY component of the path. So the
  # ACL on the mount point itself is what matters.
  #
  #   jellyfin  r-x  read-only on purpose: metadata/db live in
  #                  /var/lib/jellyfin, so it never needs to write here and a
  #                  compromised server cannot damage the library.
  #
  # Sonarr/Radarr/Transmission used to get rwx here. They were removed (see
  # media-utils.nix), so their entries are gone too.
  #
  # Library roots to add in the Jellyfin setup wizard (they live under
  # torrents/, matching the pre-existing layout on the drive):
  #   Movies → /mnt/media/torrents/Movies
  #   TV     → /mnt/media/torrents/TVShows
  #
  # Two separate mechanisms, because neither alone is sufficient:
  #
  # 1. tmpfiles sets the ACL on /mnt/media itself and a *default* ACL so
  #    files created later inherit access. This must use
  #    `systemd.tmpfiles.rules` (raw strings), NOT `systemd.tmpfiles.settings`:
  #    the structured option runs every `argument` through
  #    lib.strings.escapeC, which rewrites spaces as "\x20", producing
  #    "u:jellyfin:r-x\x20..." -- rejected by tmpfiles as an invalid ACL and
  #    skipped silently with exit 0. That is why the library was empty.
  #    The ACL field takes a BARE acl ("u:jellyfin:r-x"); the "R" prefix is
  #    not valid there ("R lines don't take argument fields").
  #
  # 2. tmpfiles cannot apply an ACL recursively, so a oneshot unit runs
  #    `setfacl -R` over the existing tree. Without this, only the top-level
  #    directory is readable and every subdirectory still denies access.
  #
  # Read-only on purpose: metadata and the database live in /var/lib/jellyfin,
  # so Jellyfin never needs to write here and a compromised server cannot
  # damage the library.
  systemd.tmpfiles.rules = [
    "a+ /mnt/media - - - - u:jellyfin:r-x"
    "a+ /mnt/media - - - - d:u:jellyfin:r-x"
  ];

  # Recursive pass over the existing tree. Runs after the mount is up and
  # after tmpfiles has set the default ACL, so newly created files inherit
  # access without needing this to run again.
  systemd.services.jellyfin-media-acl = {
    description = "Grant jellyfin read-only ACL on the media tree";
    wantedBy = [ "multi-user.target" ];
    after = [
      "mnt-media.mount"
      "systemd-tmpfiles-setup.service"
    ];
    requires = [ "mnt-media.mount" ];
    # Re-run whenever the mount or the tmpfiles rules change.
    restartTriggers = [ config.systemd.tmpfiles.rules ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Recurse over the EXISTING tree only. The default ACLs set by tmpfiles
      # above make new files inherit these rights, so this does not need to
      # run again unless the tree already existed without them.
      ${pkgs.acl}/bin/setfacl -R -m u:jellyfin:r-x /mnt/media
    '';
  };
}

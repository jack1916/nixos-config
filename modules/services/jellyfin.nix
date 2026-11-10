# Jellyfin media server.
#
# Owns the /mnt/media mount and grants the jellyfin user read-only access
# to it. The media tree itself (torrents, TV, Movies, Music) and the
# download/import stack live in media-utils.nix.
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

  # Grant the jellyfin user READ-ONLY access to the media tree.
  # Jellyfin runs as its own user; it needs to read /mnt/media/TV,
  # /mnt/media/Movies, etc. Write access is not needed — metadata
  # and database live in /var/lib/jellyfin — and withholding it means a
  # compromised server cannot modify or delete the library.
  #
  # Grant the jellyfin user READ-ONLY access to the media tree.
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
      ${pkgs.acl}/bin/setfacl -R -m u:jellyfin:r-x /mnt/media
    '';
  };
}

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

  # Declaratively grant the plex user read/write access to the media tree.
  # Applied via systemd-tmpfiles at boot (and idempotently whenever activated).
  # The R+ prefix makes it recursive; - stops descending into submounts.
  # The second rule sets a default ACL so newly created files inherit access.
  # Split into two tmpfiles files because a single file cannot repeat the
  # same rule key ("a+") for the same path.
  systemd.tmpfiles.settings = {
    "10-plex-media-access" = {
      "/mnt/media" = {
        "a+" = { argument = "R u:plex:rwx - - - -"; };
      };
    };
    "11-plex-media-default" = {
      "/mnt/media" = {
        "a+" = { argument = "d:u:plex:rwx - - - -"; };
      };
    };
  };
}

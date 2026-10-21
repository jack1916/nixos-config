# Declarative disk layout for the public VPS gateway.
#
# Targeted by nixos-anywhere / disko-install:
#   /dev/sda  ->  GPT
#     sda1    ->  EFI System Partition (vfat, 512M)  -> /boot
#     sda2    ->  Linux filesystem (ext4, rest)      -> /
#
# The same file is imported by hosts/vps/default.nix so that, once the
# machine is installed, its fileSystems.* definitions stay declared here
# (disko.devices -> fileSystems.*). nixos-anywhere only runs the
# partitioning phase (--mode disko), it does not rely on the imported
# fileSystems entries, so this is safe for the initial install too.
#
# NOTE: nvme/loop disks would need /dev/disk/by-id paths for stability;
# sda with a single controller is stable across reboots on this VPS.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          name = "ESP";
          size = "512M";
          type = "EF00"; # EFI System Partition
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          name = "root";
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}

# Declarative disk layout for the public VPS gateway.
#
# Targeted by nixos-anywhere / disko-install:
#   /dev/sda  ->  GPT
#     sda1    ->  BIOS boot partition (EF02, 1M, no filesystem)
#     sda2    ->  EFI System Partition (vfat, 512M)  -> /boot
#     sda3    ->  Linux filesystem (ext4, rest)      -> /
#
# WHY the 1M EF02 partition: Hetzner Cloud x86_64 VMs use LEGACY BIOS boot
# (see https://wiki.nixos.org/wiki/Install_NixOS_on_Hetzner_Cloud). grub
# needs an unformatted BIOS boot partition to embed its core image; without
# it the install succeeds but the machine will not boot.
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
        boot = {
          name = "boot";
          size = "1M";
          type = "EF02"; # BIOS boot partition (grub core image)
        };
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

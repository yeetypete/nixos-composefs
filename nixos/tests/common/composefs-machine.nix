# A machine booting from a disk produced by composefs-disk.nix.
{ lib, sealedSystem, ... }:
{
  imports = [ sealedSystem ];

  boot.composefs.enable = true;

  virtualisation = {
    directBoot.enable = false;
    mountHostNixStore = false;
    useEFIBoot = true;
    # Override the qemu-vm module's filesystems with the configured fileSystems.
    fileSystems = lib.mkForce { };
  };

  boot.initrd.systemd.root = "gpt-auto";
  boot.initrd.supportedFilesystems.ext4 = true;
}

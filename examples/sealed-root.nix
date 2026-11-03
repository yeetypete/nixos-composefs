{
  boot.composefs.enable = true;

  # bootc shows this as the image's version.
  system.image.version = "1";

  # The system is immutable and must be updated by deploying a new image.
  nix.enable = false;
  system.switch.enable = false;

  # Find the partition holding the composefs repository by its GPT type.
  boot.initrd.systemd.root = "gpt-auto";
  boot.initrd.supportedFilesystems.ext4 = true;

  system.stateVersion = "26.05";
}

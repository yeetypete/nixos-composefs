{
  boot.composefs.enable = true;

  # NOTE: This must increase with every image. The UKI is named after this
  # version, and systemd-boot boots the image with the highest version name
  # by default.
  system.image.version = "1";

  boot.uki.tries = 3;
  # A boot with failed units doesn't reach boot-complete.target.
  systemd.additionalUpstreamSystemUnits = [ "systemd-boot-check-no-failures.service" ];
  systemd.services.systemd-boot-check-no-failures.requiredBy = [ "boot-complete.target" ];

  # The system is immutable and must be updated by deploying a new image.
  nix.enable = false;
  system.switch.enable = false;

  # Find the partition holding the composefs repository by its GPT type.
  boot.initrd.systemd.root = "gpt-auto";
  boot.initrd.supportedFilesystems.ext4 = true;

  system.stateVersion = "26.05";
}

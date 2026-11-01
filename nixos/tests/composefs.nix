# Boot a disk with the system's sealed image deployed to a composefs
# repository.
{
  config,
  lib,
  hostPkgs,
  ...
}:
let
  inherit (config.nodes.machine) boot system systemd;
  inherit (config.node.pkgs.stdenv.hostPlatform) efiArch;

  # The UKI's name without the boot counter, e.g. nixos_1.efi for nixos_1+3.efi.
  blessedUkiFile =
    lib.replaceStrings [ "+${toString boot.uki.tries}" ] [ "" ]
      system.boot.loader.ukiFile;

  # This disk layout matches what an installer would create.
  repartDefinitions = hostPkgs.linkFarm "repart.d" (
    lib.mapAttrs (name: (hostPkgs.formats.ini { listsAsDuplicateKeys = true; }).generate name) {
      "10-esp.conf".Partition = {
        Type = "esp";
        Format = "vfat";
        SizeMinBytes = "256M";
        SizeMaxBytes = "256M";
        CopyFiles = [
          "${systemd.package}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi:/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI"
          "${system.build.uki}/${system.boot.loader.ukiFile}:/EFI/Linux/${system.boot.loader.ukiFile}"
        ];
      };
      "20-root.conf".Partition = {
        Type = "root";
        Format = "ext4";
        MakeDirectories = "/state/os/default/var";
      };
    }
  );

  disk = hostPkgs.vmTools.runInLinuxVM (
    hostPkgs.runCommand "composefs-disk"
      {
        nativeBuildInputs = [
          hostPkgs.systemd
          hostPkgs.dosfstools
          hostPkgs.e2fsprogs
          hostPkgs.util-linux
          boot.composefs.package
        ];
        preVM = hostPkgs.vmTools.createEmptyImage {
          size = 4096;
          fullName = "composefs-disk";
        };
      }
      ''
        # composefs requires fs-verity on the root's files.
        SYSTEMD_REPART_MKFS_OPTIONS_EXT4="-O verity" \
          systemd-repart --empty=require --dry-run=no --definitions=${repartDefinitions} /dev/vda

        mount --mkdir /dev/vda2 /mnt
        cfsctl --repo /mnt/composefs init
        cfsctl --repo /mnt/composefs oci pull --bootable oci:${system.build.composefsImage}:latest nixos
        # composefs-setup-root requires the deployment's state directory.
        mkdir -p /mnt/state/deploy/$(< ${system.build.composefsDigest})
        umount /mnt
      ''
  );
in
{
  name = "composefs";

  nodes.machine = {
    boot.composefs.enable = true;
    environment.systemPackages = [ boot.composefs.package ];

    virtualisation = {
      directBoot.enable = false;
      mountHostNixStore = false;
      useEFIBoot = true;
      # Override the qemu-vm module's filesystems with the configured fileSystems.
      fileSystems = lib.mkForce { };
    };

    boot.initrd.systemd.root = "gpt-auto";
    boot.initrd.supportedFilesystems.ext4 = true;
  };

  testScript =
    { nodes, ... }:
    ''
      import json
      import os
      import subprocess
      import tempfile
      from pathlib import Path

      tmp_disk_image = tempfile.NamedTemporaryFile()
      subprocess.run([
        "${nodes.machine.virtualisation.qemu.package}/bin/qemu-img",
        "create", "-f", "qcow2", "-b", "${disk}/disk-image.qcow2", "-F", "qcow2",
        tmp_disk_image.name,
      ], check=True)
      os.environ["NIX_DISK_IMAGE"] = tmp_disk_image.name

      machine.wait_for_unit("multi-user.target")

      with subtest("The system is running"):
        _, state = machine.execute("systemctl is-system-running --wait")
        t.assertEqual(state.strip(), "running")

      with subtest("The root is a transient overlay of the composefs image"):
        digest = Path("${system.build.composefsDigest}").read_text().strip()
        t.assertIn(f"composefs.digest=v1-sha512-12:{digest}", machine.succeed("cat /proc/cmdline"))
        t.assertEqual(machine.succeed("findmnt --noheadings --output FSTYPE,SOURCE /").split(), ["overlay", "transient"])

      with subtest("The UKI name matches the booted entry"):
        t.assertIn("Current Entry: ${blessedUkiFile}", machine.succeed("bootctl status"))

      with subtest("A successful boot removes the UKI's boot counter"):
        machine.wait_for_unit("systemd-boot-check-no-failures.service")
        machine.wait_for_unit("systemd-bless-boot.service")
        machine.succeed("test -e /boot/EFI/Linux/${blessedUkiFile}")
        machine.fail("test -e /boot/EFI/Linux/${system.boot.loader.ukiFile}")

      with subtest("The ESP is mounted at /boot"):
        t.assertEqual(machine.succeed("bootctl --print-esp-path").strip(), "/boot")

      with subtest("The deployed image is labelled with its version"):
        config = json.loads(machine.succeed("cfsctl --repo /sysroot/composefs oci inspect --config nixos"))
        t.assertEqual(config["config"]["Labels"]["org.opencontainers.image.version"], "${system.image.version}")

      with subtest("The deployed image contains the UKI and systemd-boot"):
        dump = machine.succeed("cfsctl --repo /sysroot/composefs oci dump nixos")
        t.assertIn("/boot/EFI/Linux/${system.boot.loader.ukiFile} ", dump)
        t.assertIn("/boot/EFI/systemd/systemd-boot${efiArch}.efi ", dump)

      with subtest("The physical root with the repository is at /sysroot"):
        machine.succeed("test -d /sysroot/composefs/images")

      with subtest("/var persists, the rest of the root is transient"):
        t.assertIn("/state/os/default/var", machine.succeed("findmnt --noheadings --output SOURCE /var"))
        machine.succeed("touch /var/persistent /etc/transient")
        machine.shutdown()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("test -e /var/persistent")
        machine.fail("test -e /etc/transient")
    '';
}

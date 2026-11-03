# Returns Python to install the machine's sealed image on a disk with bootc, and
# to boot the machine from it. Needs a node from composefs-installer.nix.
{ machine }:
''
  import os

  installer.start()
  installer.wait_for_unit("multi-user.target")
  installer.succeed(
    "bootc install to-disk"
    " --source-imgref oci:${machine.system.build.composefsImage}:latest"
    " --target-imgref localhost/nixos:latest"
    " --composefs-backend --bootloader systemd --filesystem ext4 --generic-image"
    " --wipe /dev/vdb >&2",
    timeout=900,
  )
  installer.shutdown()
  os.environ["NIX_DISK_IMAGE"] = str(installer.state_dir / "empty0.qcow2")
''

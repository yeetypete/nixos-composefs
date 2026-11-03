# Install the system's sealed image with bootc, boot the disk, then switch to
# an update and roll back.
{ nodes, ... }:
let
  generation = number: {
    imports = [ ./common/composefs-machine.nix ];
    environment.etc.composefs-generation.text = number;
  };
in
{
  name = "composefs";

  nodes.installer = ./common/composefs-installer.nix;

  nodes.machine = {
    imports = [ (generation "1") ];
    # The update's image, shared outside the image so that it doesn't change.
    virtualisation.qemu.options = [
      "-virtfs local,path=${nodes.update.system.build.composefsImage},security_model=none,readonly=on,mount_tag=update"
    ];
  };
  # Only built, for the machine to switch to.
  nodes.update = generation "2";

  testScript =
    { nodes, ... }:
    ''
      ${import ./common/composefs-disk.nix { machine = nodes.machine; }}

      machine.wait_for_unit("multi-user.target")

      ${import ./common/composefs-subtests.nix { machine = nodes.machine; }}

      def booted_generation():
        return bootc_booted()["composefs"]["verity"], machine.succeed("cat /etc/composefs-generation").strip()

      with subtest("bootc switches to an update and rolls back"):
        machine.succeed("touch /var/before-update")
        first, number = booted_generation()
        t.assertEqual(number, "1")
        machine.succeed("mkdir -p /run/update && mount -t 9p -o trans=virtio,version=9p2000.L,ro update /run/update")
        machine.succeed("bootc switch --transport oci /run/update:latest >&2")
        machine.shutdown()
        machine.wait_for_unit("multi-user.target")
        second, number = booted_generation()
        t.assertEqual(number, "2")
        t.assertNotEqual(first, second)
        machine.succeed("test -e /var/before-update")
        machine.succeed("bootc rollback >&2")
        machine.shutdown()
        machine.wait_for_unit("multi-user.target")
        t.assertEqual(booted_generation(), (first, "1"))
    '';
}

# Python subtests for a machine booted from composefs-disk.nix.
{ machine }:
let
  inherit (machine) system;
in
''
  import json
  from pathlib import Path

  def bootc_booted():
    return json.loads(machine.succeed("bootc status --format json"))["status"]["booted"]

  with subtest("The system is running"):
    _, state = machine.execute("systemctl is-system-running --wait")
    t.assertEqual(state.strip(), "running", machine.succeed("systemctl --failed --no-legend"))

  with subtest("The root is a transient overlay of the composefs image"):
    digest = Path("${system.build.composefsDigest}").read_text().strip()
    t.assertIn(f"composefs.digest=v1-sha512-12:{digest}", machine.succeed("cat /proc/cmdline"))
    t.assertEqual(
      machine.succeed("findmnt --noheadings --output FSTYPE,SOURCE /").split(),
      ["overlay", f"transient:composefs={digest}"],
    )

  with subtest("bootc booted the UKI it installed"):
    booted = bootc_booted()
    t.assertEqual(booted["composefs"]["bootType"].lower(), "uki")
    t.assertEqual(booted["composefs"]["verity"], digest)
    machine.succeed(f"test -e /boot/EFI/Linux/bootc/bootc_composefs-{digest}.efi")

  with subtest("The ESP is mounted at /boot"):
    t.assertEqual(machine.succeed("bootctl --print-esp-path").strip(), "/boot")

  with subtest("The deployed image is labelled with its version"):
    t.assertEqual(bootc_booted()["image"]["version"], "${system.image.version}")

  with subtest("The physical root with the repository is read-only at /sysroot"):
    machine.succeed("test -d /sysroot/composefs/images")
    t.assertIn("ro", machine.succeed("findmnt --noheadings --output OPTIONS /sysroot").strip().split(","))
    machine.fail("rm -rf /sysroot/state")
    machine.succeed("test -d /sysroot/state/deploy")

  with subtest("/var persists, the rest of the root is transient"):
    t.assertIn("/state/os/default/var", machine.succeed("findmnt --noheadings --output SOURCE /var"))
    machine.succeed("touch /var/persistent /etc/transient")
    machine.shutdown()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -e /var/persistent")
    machine.fail("test -e /etc/transient")
''

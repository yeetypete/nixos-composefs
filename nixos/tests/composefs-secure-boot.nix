# Boot the sealed image with Secure Boot enforced, signed offline with keys
# that systemd-boot enrolls on the first boot.
{ hostPkgs, ... }:
let
  keys = hostPkgs.callPackage ./secure-boot-keys.nix { };

  # Stands in for an external signer.
  sign =
    config: name:
    hostPkgs.runCommand "${name}.sig" { nativeBuildInputs = [ hostPkgs.openssl ]; } ''
      openssl dgst -sha256 -sign ${keys}/db.key -out $out \
        ${config.system.build.composefsSignedData.${name}}
    '';
in
{
  name = "composefs-secure-boot";

  nodes.installer = ./common/composefs-installer.nix;

  nodes.machine =
    { config, ... }:
    {
      imports = [ ./common/composefs-machine.nix ];

      boot.composefs.secureBoot = {
        enable = true;
        certificate = "${keys}/db.pem";
        enrollKeys = "${keys}/auto";
        signatures = {
          uki = sign config "uki";
          systemd-boot = sign config "systemd-boot";
        };
      };
    };

  testScript =
    { nodes, ... }:
    ''
      ${import ./common/composefs-disk.nix { machine = nodes.machine; }}

      # systemd-boot enrolls the keys and reboots.
      machine.start(allow_reboot=True)
      machine.wait_for_unit("multi-user.target")

      with subtest("The system booted with Secure Boot enabled"):
        t.assertIn("Secure Boot: enabled (user)", machine.succeed("bootctl status"))

      ${import ./common/composefs-subtests.nix { machine = nodes.machine; }}
    '';
}

# Boot the machine from the Secure Boot test and open a root shell in it.
{ lib, hostPkgs, ... }:
{
  imports = [ ./composefs-secure-boot.nix ];

  name = lib.mkForce "composefs-shell";

  sshBackdoor.enable = true;

  testScript = lib.mkForce (
    { nodes, ... }:
    ''
      ${import ./common/composefs-disk.nix { machine = nodes.machine; }}

      import subprocess

      # systemd-boot enrolls the keys and reboots.
      machine.start(allow_reboot=True)
      machine.wait_for_unit("multi-user.target")
      serial_stdout_off()

      subprocess.run(["${lib.getExe hostPkgs.openssh_gssapi}", f"vsock-mux/{machine.vsock_host}"])
    ''
  );
}

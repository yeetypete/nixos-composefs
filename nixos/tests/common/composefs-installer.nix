# Installs the machine's sealed image on an empty disk, see composefs-disk.nix.
{ nodes, ... }:
{
  virtualisation = {
    emptyDiskImages = [ 8192 ];
    memorySize = 4096;
    containers.enable = true;
  };
  environment.systemPackages = [ nodes.machine.boot.composefs.package ];
}

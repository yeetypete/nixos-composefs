# nixpkgs' bootc, updated to the upstream release with the composefs backend.
# Drop the version bump once nixpkgs has caught up.
#
# The `initramfs` output holds what the initrd needs, initramfs-setup and its
# unit, so that bootc's own closure stays out of the initrd.
{
  lib,
  bootc,
  fetchFromGitHub,
  rustPlatform,
  makeWrapper,
  dosfstools,
  e2fsprogs,
  podman,
  skopeo,
  systemd,
  util-linux,
}:

bootc.overrideAttrs (
  finalAttrs: previousAttrs: {
    version = "1.17.3";

    src = fetchFromGitHub {
      owner = "bootc-dev";
      repo = "bootc";
      rev = "v${finalAttrs.version}";
      hash = "sha256-7HFYGKSCD1T559Y4fL7iTLy7bXI3Bei+RmGP/PVxzfM=";
    };
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      hash = "sha256-Ahj/3emwKVIOC2g1kJzAJsA2zAQ2TEgcFM8STGt05Tg=";
    };
    # Already part of the release.
    patches = [ ];

    # Like the Makefile's `bin` target, without SELinux, which NixOS doesn't use.
    # overrideAttrs: set what cargoBuildHook reads, not buildRustPackage's arguments.
    cargoBuildNoDefaultFeatures = true;
    cargoBuildFeatures = [
      "install-to-disk"
      "pre-6.15"
    ];
    cargoBuildFlags = previousAttrs.cargoBuildFlags ++ [
      "-p"
      "bootc-initramfs-setup"
    ];
    doCheck = false;

    outputs = [
      "out"
      "initramfs"
    ];
    nativeBuildInputs = previousAttrs.nativeBuildInputs ++ [ makeWrapper ];

    # See the Makefile's install target.
    postInstall = (previousAttrs.postInstall or "") + ''
      install -D -m 0755 $out/bin/bootc-initramfs-setup $initramfs/lib/bootc/initramfs-setup
      rm $out/bin/bootc-initramfs-setup
      install -D -m 0644 -t $initramfs/lib/systemd/system crates/initramfs/bootc-root-setup.service
      substituteInPlace $initramfs/lib/systemd/system/bootc-root-setup.service \
        --replace-fail /usr/lib/bootc/initramfs-setup $initramfs/lib/bootc/initramfs-setup

      # The units the composefs backend uses. The others only run on ostree
      # systems.
      install -D -m 0644 -t $out/lib/systemd/system \
        systemd/bootc-finalize-staged.service \
        systemd/bootc-finalize-staged-hold.service
      substituteInPlace $out/lib/systemd/system/*.service \
        --replace-fail /usr/bin/bootc $out/bin/bootc
    '';

    # What bootc runs to pull and store images and to install to a disk.
    # Suffixed, so that the host's own tools win.
    postFixup = (previousAttrs.postFixup or "") + ''
      wrapProgram $out/bin/bootc --suffix PATH : ${
        lib.makeBinPath [
          dosfstools
          e2fsprogs
          podman
          skopeo
          systemd
          util-linux
        ]
      }
    '';
  }
)

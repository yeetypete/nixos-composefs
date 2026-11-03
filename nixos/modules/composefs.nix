{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.boot.composefs;

  settingsFormat = pkgs.formats.toml { };

  inherit (config.system.boot.loader) ukiFile;
  systemdBootFile = "systemd-boot${pkgs.stdenv.hostPlatform.efiArch}.efi";

  # The binaries in /boot in the image, named as in secureBoot.signatures.
  bootFiles = {
    uki = {
      source = "${config.system.build.uki}/${ukiFile}";
      target = "EFI/Linux/${ukiFile}";
    };
    systemd-boot = {
      source = "${config.systemd.package}/lib/systemd/boot/efi/${systemdBootFile}";
      target = "EFI/systemd/${systemdBootFile}";
    };
  };

  setupRootConf = settingsFormat.generate "setup-root-conf.toml" cfg.setupRoot.settings;

  sbsign = "${pkgs.buildPackages.systemd}/lib/systemd/systemd-sbsign";

  # The data to sign offline for a binary, e.g. with:
  #   openssl dgst -sha256 -sign secure-boot-private-key.pem -out uki.sig uki
  signedData =
    file:
    pkgs.runCommand "nixos-composefs-signed-data-${baseNameOf file.target}" { } ''
      ${sbsign} sign --certificate=${cfg.secureBoot.certificate} --prepare-offline-signing \
        --output=$out ${file.source}
    '';

  # A binary with its offline signature attached, once verified.
  signed =
    name: file:
    let
      inherit (cfg.secureBoot) certificate;
      data = signedData file;
      signature = cfg.secureBoot.signatures.${name};
    in
    pkgs.runCommand "nixos-composefs-signed-${baseNameOf file.target}"
      { nativeBuildInputs = [ pkgs.openssl ]; }
      ''
        openssl dgst -sha256 -signature ${signature} \
          -verify <(openssl x509 -pubkey -noout -in ${certificate}) ${data}
        ${sbsign} sign --certificate=${certificate} \
          --signed-data=${data} --signed-data-signature=${signature} \
          --output=$out ${file.source}
      '';

  # Referencing the toplevel in a label puts its closure in the image.
  image = pkgs.dockerTools.streamLayeredImage {
    name = "nixos";
    extraCommands = ''
      mkdir -p usr/lib/composefs boot sysroot etc var run proc sys dev tmp
      chmod 1777 tmp
      # bootctl --root and bootc read these from the image.
      cp ${config.environment.etc."os-release".source} usr/lib/os-release
      cp ${setupRootConf} usr/lib/composefs/setup-root-conf.toml
    ''
    # bootctl install --root takes systemd-boot*.efi.signed over the unsigned
    # binary, from where its systemd keeps systemd-boot. This is outside /boot,
    # so unlike the UKI's, this signature is part of the composefs digest.
    + lib.optionalString cfg.secureBoot.enable ''
      dir=.${dirOf bootFiles.systemd-boot.source}
      mkdir -p $dir
      cp ${signed "systemd-boot" bootFiles.systemd-boot} $dir/${systemdBootFile}.signed
      chmod -R a-w .${config.systemd.package}
      # bootc stages these for systemd-boot to enroll.
      mkdir -p usr/lib/bootc/install/secureboot-keys
      cp -r ${cfg.secureBoot.enrollKeys} usr/lib/bootc/install/secureboot-keys/auto
    '';
    config.Labels = {
      "containers.bootc" = "1";
      "org.nixos.toplevel" = "${config.system.build.toplevel}";
    }
    // lib.optionalAttrs (config.system.image.version != null) {
      "org.opencontainers.image.version" = config.system.image.version;
    };
  };

  # cfsctl, as bootc computes the digest when it pulls the image. The build's
  # filesystem may lack fs-verity, which computing the digest doesn't need.
  # TERM=dumb hides its progress bars.
  cfs = ''
    export TERM=dumb
    cfs() { bootc internals cfs -- --repo $PWD/repo "$@"; }
    bootc internals cfs -- init --insecure $PWD/repo
  '';

  # intermediate system image without the UKI
  intermediateImage =
    pkgs.runCommand
      "nixos-composefs-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}-intermediate"
      { nativeBuildInputs = [ pkgs.skopeo ]; }
      ''
        ${image} > image.tar
        skopeo --insecure-policy copy --quiet docker-archive:image.tar oci:$out:latest
      '';
in
{
  options.boot.composefs = {
    enable = lib.mkEnableOption "booting from a sealed composefs image";

    package = lib.mkPackageOption pkgs "bootc" { };

    buildPackage = lib.mkPackageOption pkgs "bootc" {
      # We use buildPackages so that the digest is computed with the build
      # platform's bootc, allowing for cross-compiled systems to work.
      default = [
        "buildPackages"
        "bootc"
      ];
    };

    secureBoot = {
      enable = lib.mkEnableOption "Secure Boot signatures for the UKI and systemd-boot in the image";

      certificate = lib.mkOption {
        type = lib.types.path;
        description = "The db certificate the signatures are verified against.";
      };

      enrollKeys = lib.mkOption {
        type = lib.types.path;
        description = "A directory of PK, KEK and db .auth files for systemd-boot to enroll.";
      };

      signatures = {
        uki = lib.mkOption {
          type = lib.types.path;
          description = ''
            Offline signature of `config.system.build.composefsSignedData.uki`,
            e.g. from `openssl dgst -sha256 -sign <key>`.
            See {manpage}`systemd-sbsign(8)`.
          '';
        };

        systemd-boot = lib.mkOption {
          type = lib.types.path;
          description = ''
            Offline signature of `config.system.build.composefsSignedData.systemd-boot`.
            It is part of the image's composefs digest, so sign this before the UKI.
          '';
        };
      };
    };

    setupRoot = {
      settings = lib.mkOption {
        type = lib.types.submodule { freeformType = settingsFormat.type; };
        default = { };
        description = ''
          Configuration for bootc-root-setup.service,
          see {manpage}`bootc-setup-root-conf(5)`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # The image's UKI is the boot entry.
    boot.loader.grub.enable = lib.mkDefault false;

    # An immutable system.etc.overlay sets this placeholder itself.
    #
    # If possible, prefer setting `boot.kernelParams = [ "systemd.machine_id=firmware" ]`
    # for a stable machine ID. Note that this depends on the firmware reporting
    # a unique product UUID.
    environment.etc.machine-id =
      lib.mkIf (!(config.system.etc.overlay.enable && !config.system.etc.overlay.mutable))
        (
          lib.mkDefault {
            text = "";
            mode = "0444";
          }
        );

    boot.composefs.setupRoot.settings = {
      # A tmpfs over the image, as NixOS writes to the root while booting.
      root.transient = lib.mkDefault true;
      # NixOS sets up /etc itself, in the transient root.
      etc.mount = lib.mkDefault "none";
    };

    boot.initrd.availableKernelModules = [
      "loop"
      "erofs"
      "overlay"
    ];

    system.requiredKernelConfig = with config.lib.kernelConfig; [
      (isEnabled "EROFS_FS")
    ];

    boot.initrd.systemd = {
      packages = [ cfg.package.initramfs ];
      storePaths = [ cfg.package.initramfs ];
      contents."/usr/lib/composefs/setup-root-conf.toml".source = setupRootConf;

      # bootc's unit replaces the physical root at /sysroot with the image, which
      # NixOS then looks for its closure, /etc and /run in.
      services.bootc-root-setup = {
        before = [
          "initrd-find-nixos-closure.service"
          "initrd-find-etc.service"
          "sysroot-etc.mount"
          "sysroot-run.mount"
        ];
        wantedBy = [ "initrd-root-fs.target" ];
      };
    };

    environment.systemPackages = [ cfg.package ];
    systemd.packages = [ cfg.package ];
    # Pulling from a registry or containers-storage needs /etc/containers.
    virtualisation.containers.enable = true;

    # The composefs digest of the image's root filesystem.
    system.build.composefsDigest =
      pkgs.runCommand
        "nixos-composefs-digest-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}"
        { nativeBuildInputs = [ cfg.buildPackage ]; }
        ''
          ${cfs}
          cfs oci pull oci:${intermediateImage}:latest nixos
          cfs --erofs-version 1 oci compute-id --bootable nixos > $out
        '';

    # UKI with embedded composefs digest from intermediateImage
    system.build.uki =
      let
        cmdline = "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}";
      in
      # override the default UKI
      lib.mkOverride 99 (
        pkgs.runCommand ukiFile { nativeBuildInputs = [ pkgs.buildPackages.systemdUkify ]; } ''
          mkdir -p $out
          ukify build \
            --config=${config.boot.uki.configFile} \
            --cmdline="${cmdline} composefs.digest=v1-sha512-12:$(< ${config.system.build.composefsDigest})" \
            --output="$out/${ukiFile}"
        ''
      );

    # The data to sign offline for each binary, by the names in secureBoot.signatures.
    system.build.composefsSignedData = lib.mkIf cfg.secureBoot.enable (
      lib.mapAttrs (_: signedData) bootFiles
    );

    # The image's /boot: the UKI, optionally signed.
    system.build.composefsBoot = pkgs.runCommand "nixos-composefs-boot" { } ''
      install -D -m 0644 ${
        if cfg.secureBoot.enable then signed "uki" bootFiles.uki else bootFiles.uki.source
      } $out/${bootFiles.uki.target}
    '';

    # final system image is created from the intermediate image by injecting the UKI from above,
    # as an OCI image layout addressed as oci:<path>:latest
    system.build.composefsImage =
      pkgs.runCommand
        "nixos-composefs-image-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}"
        {
          nativeBuildInputs = [
            pkgs.umoci
            cfg.buildPackage
          ];
        }
        ''
          cp -r --no-preserve=mode ${intermediateImage} $out
          cp -r --no-preserve=mode ${config.system.build.composefsBoot} boot
          tar --create --file layer.tar \
            --sort=name --mtime=@1 --owner=0 --group=0 --numeric-owner boot
          umoci raw add-layer --image $out:latest --no-history --compress none layer.tar
          umoci gc --layout $out

          # Adding the UKI must not change the image's digest.
          ${cfs}
          cfs oci pull oci:$out:latest nixos
          [ "$(cfs --erofs-version 1 oci compute-id --bootable nixos)" = "$(< ${config.system.build.composefsDigest})" ]
        '';
  };
}

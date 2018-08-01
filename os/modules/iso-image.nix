# This module creates a bootable ISO image containing the given vpsAdminOS
# configuration.  The derivation for the ISO image will be placed in
# config.system.build.isoImage.

{ config, lib, pkgs, ... }:

with lib;

let
  # Timeout in syslinux is in units of 1/10 of a second.
  # 0 is used to disable timeouts.
  syslinuxTimeout = if config.boot.loader.timeout == null then
      0
    else
      max (config.boot.loader.timeout * 10) 1;


  max = x: y: if x > y then x else y;

  # The configuration file for syslinux.

  # Notes on syslinux configuration and UNetbootin compatiblity:
  #   * Do not use '/syslinux/syslinux.cfg' as the path for this
  #     configuration. UNetbootin will not parse the file and use it as-is.
  #     This results in a broken configuration if the partition label does
  #     not match the specified config.isoImage.volumeID. For this reason
  #     we're using '/isolinux/isolinux.cfg'.
  #   * Use APPEND instead of adding command-line arguments directly after
  #     the LINUX entries.
  #   * COM32 entries (chainload, reboot, poweroff) are not recognized. They
  #     result in incorrect boot entries.

  baseIsolinuxCfg = ''
    SERIAL 0 38400
    TIMEOUT ${builtins.toString syslinuxTimeout}
    UI vesamenu.c32
    MENU TITLE vpsAdminOS
    MENU BACKGROUND /isolinux/background.png
    DEFAULT boot

    LABEL boot
    MENU LABEL vpsAdminOS ${config.system.osVersion} (${config.system.osCodeName})
    LINUX /boot/bzImage
    APPEND systemConfig=${config.system.build.toplevel} ${toString config.boot.kernelParams}
    INITRD /boot/initrd
  '';

  isolinuxMemtest86Entry = ''
    LABEL memtest
    MENU LABEL Memtest86+
    LINUX /boot/memtest.bin
    APPEND ${toString config.isoImage.memtest86.params}
  '';

  isolinuxCfg = baseIsolinuxCfg + (optionalString config.isoImage.memtest86.enable isolinuxMemtest86Entry);

  # The EFI boot image.
  efiDir = pkgs.runCommand "efi-directory" {} ''
    mkdir -p $out/EFI/boot
    cp -v ${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${targetArch}.efi $out/EFI/boot/boot${targetArch}.efi
    mkdir -p $out/loader/entries

    cat << EOF > $out/loader/entries/nixos-iso.conf
    title vpsAdminOS
    linux /boot/bzImage
    initrd /boot/initrd
    options systemConfig=${config.system.build.toplevel} ${toString config.boot.kernelParams}
    EOF
  '';

  efiImg = pkgs.runCommand "efi-image_eltorito" { buildInputs = [ pkgs.mtools pkgs.libfaketime ]; }
    # Be careful about determinism: du --apparent-size,
    #   dates (cp -p, touch, mcopy -m, faketime for label), IDs (mkfs.vfat -i)
    ''
      mkdir ./contents && cd ./contents
      cp -rp "${efiDir}"/* .
      mkdir ./boot
      cp -p "${config.boot.kernelPackages.kernel}/bzImage" \
        "${config.system.build.initialRamdisk}/initrd" ./boot/
      touch --date=@0 ./*

      usage_size=$(du -sb --apparent-size . | tr -cd '[:digit:]')
      # Make the image 110% as big as the files need to make up for FAT overhead
      image_size=$(( ($usage_size * 110) / 100 ))
      # Make the image fit blocks of 1M
      block_size=$((1024*1024))
      image_size=$(( ($image_size / $block_size + 1) * $block_size ))
      echo "Usage size: $usage_size"
      echo "Image size: $image_size"
      truncate --size=$image_size "$out"
      ${pkgs.libfaketime}/bin/faketime "2000-01-01 00:00:00" ${pkgs.dosfstools}/sbin/mkfs.vfat -i 12345678 -n EFIBOOT "$out"
      mcopy -bpsvm -i "$out" ./* ::
    ''; # */

  targetArch = if pkgs.stdenv.isi686 then
    "ia32"
  else if pkgs.stdenv.isx86_64 then
    "x64"
  else
    throw "Unsupported architecture";

in

{
  options = {

    isoImage.isoName = mkOption {
      default = "${config.isoImage.isoBaseName}.iso";
      description = ''
        Name of the generated ISO image file.
      '';
    };

    isoImage.isoBaseName = mkOption {
      default = "vpsadminos";
      description = ''
        Prefix of the name of the generated ISO image file.
      '';
    };

    isoImage.compressImage = mkOption {
      default = false;
      description = ''
        Whether the ISO image should be compressed using
        <command>bzip2</command>.
      '';
    };

    isoImage.volumeID = mkOption {
      default = "VPSADMINOS_BOOT_CD";
      description = ''
        Specifies the label or volume ID of the generated ISO image.
        Note that the label is used by stage 1 of the boot process to
        mount the CD, so it should be reasonably distinctive.
      '';
    };

    isoImage.contents = mkOption {
      example = literalExample ''
        [ { source = pkgs.memtest86 + "/memtest.bin";
            target = "boot/memtest.bin";
          }
        ]
      '';
      description = ''
        This option lists files to be copied to fixed locations in the
        generated ISO image.
      '';
    };

    isoImage.storeContents = mkOption {
      example = literalExample "[ pkgs.stdenv ]";
      description = ''
        This option lists additional derivations to be included in the
        Nix store in the generated ISO image.
      '';
    };

    isoImage.includeSystemBuildDependencies = mkOption {
      default = false;
      description = ''
        Set this option to include all the needed sources etc in the
        image. It significantly increases image size. Use that when
        you want to be able to keep all the sources needed to build your
        system or when you are going to install the system on a computer
        with slow or non-existent network connection.
      '';
    };

    isoImage.makeEfiBootable = mkOption {
      default = false;
      description = ''
        Whether the ISO image should be an efi-bootable volume.
      '';
    };

    isoImage.makeUsbBootable = mkOption {
      default = false;
      description = ''
        Whether the ISO image should be bootable from CD as well as USB.
      '';
    };

    isoImage.splashImage = mkOption {
      default = ../../artwork/boot.png;
      description = ''
        The splash image to use in the bootloader.
      '';
    };

    isoImage.memtest86 = {
      enable = mkEnableOption "Add memtest86 to ISO image";
      params = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "console=ttyS0,115200" ];
        description = ''
          Parameters added to the Memtest86+ command line.
        '';
      };
    };

  };

  config = {
    environment.systemPackages = [ pkgs.syslinux ];

    # In stage 1 of the boot, mount the CD as the root FS by label so
    # that we don't need to know its device.  We pass the label of the
    # root filesystem on the kernel command line, rather than in
    # `fileSystems' below.  This allows CD-to-USB converters such as
    # UNetbootin to rewrite the kernel command line to pass the label or
    # UUID of the USB stick.  It would be nicer to write
    # `root=/dev/disk/by-label/...' here, but UNetbootin doesn't
    # recognise that.
    boot.kernelParams =
      [ "root=LABEL=${config.isoImage.volumeID}"
      ];

    boot.initrd.kernelModules = [ "loop" "iso9660" "usb-storage" "uas" ];

    boot.initrd.postDeviceCommands = ''
      mkdir /media

      echo -n "mounting media "
      trial=0
      until msg="$(mount $root /media 2>&1)"; do
        sleep 0.25
        echo -n .
        trial=$(($trial + 1))
        if [[ $trial -eq 100 ]]; then
          echo
          fail "Can't mount media from $root ($msg)"
          break
        fi
      done
      echo
      root=/media/nix-store.squashfs
      '';

    # Add vfat support to the initrd to enable people to copy the
    # contents of the CD to a bootable USB stick.
    boot.initrd.supportedFilesystems = [ "vfat" ];

    system.qemuParams = [
      "-cdrom ${config.system.build.isoImage}/iso/${config.isoImage.isoName}"
      "-boot d"
    ];

    # Closures to be copied to the Nix store on the CD, namely the init
    # script and the top-level system configuration directory.
    isoImage.storeContents =
      [ config.system.build.toplevel ] ++
      optional config.isoImage.includeSystemBuildDependencies
        config.system.build.toplevel.drvPath;

    # Create the squashfs image that contains the Nix store.
    system.build.squashfsStore = pkgs.callPackage <nixpkgs/nixos/lib/make-squashfs.nix> {
      #inherit (pkgs) stdenv squashfsTools perl pathsFromGraph;
      storeContents = config.isoImage.storeContents;
    };

    # Individual files to be included on the CD, outside of the Nix
    # store on the CD.
    isoImage.contents =
      [ { source = pkgs.substituteAll  {
            name = "isolinux.cfg";
            src = pkgs.writeText "isolinux.cfg-in" isolinuxCfg;
            bootRoot = "/boot";
          };
          target = "/isolinux/isolinux.cfg";
        }
        { source = config.boot.kernelPackages.kernel + "/bzImage";
          target = "/boot/bzImage";
        }
        { source = config.system.build.initialRamdisk + "/initrd";
          target = "/boot/initrd";
        }
        { source = config.system.build.squashfsStore;
          target = "/nix-store.squashfs";
        }
        { source = "${pkgs.syslinux}/share/syslinux";
          target = "/isolinux";
        }
        { source = config.isoImage.splashImage;
          target = "/isolinux/background.png";
        }
        { source = pkgs.writeText "version" config.system.osVersion;
          target = "/version.txt";
        }
      ] ++ optionals config.isoImage.makeEfiBootable [
        { source = efiImg;
          target = "/boot/efi.img";
        }
        { source = "${efiDir}/EFI";
          target = "/EFI";
        }
        { source = "${efiDir}/loader";
          target = "/loader";
        }
      ] ++ optionals config.isoImage.memtest86.enable [
        { source = "${pkgs.memtest86plus}/memtest.bin";
          target = "/boot/memtest.bin";
        }
      ];

    boot.loader.timeout = 10;

    # Create the ISO image.
    system.build.isoImage = pkgs.callPackage <nixpkgs/nixos/lib/make-iso9660-image.nix> ({
      inherit (pkgs) stdenv perl xorriso syslinux;

      inherit (config.isoImage) isoName compressImage volumeID contents;

      bootable = true;
      bootImage = "/isolinux/isolinux.bin";
    } // optionalAttrs config.isoImage.makeUsbBootable {
      usbBootable = true;
      isohybridMbrImage = "${pkgs.syslinux}/share/syslinux/isohdpfx.bin";
    } // optionalAttrs config.isoImage.makeEfiBootable {
      efiBootable = true;
      efiBootImage = "boot/efi.img";
    });

    # XXX: we don't support this yet
    #boot.postBootCommands =
    #  ''
    #    # After booting, register the contents of the Nix store on the
    #    # CD in the Nix database in the tmpfs.
    #    ${config.nix.package.out}/bin/nix-store --load-db < /nix/store/nix-path-registration

    #    # nixos-rebuild also requires a "system" profile and an
    #    # /etc/NIXOS tag.
    #    touch /etc/NIXOS
    #    ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
    #  '';
  };
}

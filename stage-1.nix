{ lib, pkgs, config, ... }:
with lib;
let
  modulesTree = config.system.modulesTree;
  modules = pkgs.makeModulesClosure {
    rootModules = config.boot.initrd.availableKernelModules ++ config.boot.initrd.kernelModules;
    allowMissing = true;
    kernel = modulesTree;
  };
  dhcpcd = pkgs.dhcpcd.override { udev = null; };
  extraUtils = pkgs.runCommandCC "extra-utils"
  {
    buildInputs = [ pkgs.nukeReferences ];
    allowedReferences = [ "out" ];
  } ''
    set +o pipefail
    mkdir -p $out/bin $out/lib
    ln -s $out/bin $out/sbin

    copy_bin_and_libs() {
      [ -f "$out/bin/$(basename $1)" ] && rm "$out/bin/$(basename $1)"
      cp -pd $1 $out/bin
    }

    # Copy Busybox
    for BIN in ${pkgs.busybox}/{s,}bin/*; do
      copy_bin_and_libs $BIN
    done

    copy_bin_and_libs ${pkgs.dhcpcd}/bin/dhcpcd

    # Copy ld manually since it isn't detected correctly
    cp -pv ${pkgs.glibc.out}/lib/ld*.so.? $out/lib

    # Copy all of the needed libraries
    find $out/bin $out/lib -type f | while read BIN; do
      echo "Copying libs for executable $BIN"
      LDD="$(ldd $BIN)" || continue
      LIBS="$(echo "$LDD" | awk '{print $3}' | sed '/^$/d')"
      for LIB in $LIBS; do
        TGT="$out/lib/$(basename $LIB)"
        if [ ! -f "$TGT" ]; then
          SRC="$(readlink -e $LIB)"
          cp -pdv "$SRC" "$TGT"
        fi
      done
    done

    # Strip binaries further than normal.
    chmod -R u+w $out
    stripDirs "lib bin" "-s"

    # Run patchelf to make the programs refer to the copied libraries.
    find $out/bin $out/lib -type f | while read i; do
      if ! test -L $i; then
        nuke-refs -e $out $i
      fi
    done

    find $out/bin -type f | while read i; do
      if ! test -L $i; then
        echo "patching $i..."
        patchelf --set-interpreter $out/lib/ld*.so.? --set-rpath $out/lib $i || true
      fi
    done

    # Make sure that the patchelf'ed binaries still work.
    echo "testing patched programs..."
    $out/bin/ash -c 'echo hello world' | grep "hello world"
    export LD_LIBRARY_PATH=$out/lib
    $out/bin/mount --help 2>&1 | grep -q "BusyBox"
  '';
  shell = "${extraUtils}/bin/ash";
  dhcpHook = pkgs.writeScript "dhcpHook" ''
  #!${shell}
  '';
  bootStage1 = pkgs.writeScript "stage1" ''
    #!${shell}
    echo
    echo "[1;32m<<< vpsAdminOs Stage 1 >>>[0m"
    echo

    export PATH=${extraUtils}/bin/
    mkdir -p /proc /sys /dev /etc/udev /tmp /run/ /lib/ /mnt/ /var/log /bin
    mount -t devtmpfs devtmpfs /dev/
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys

    ln -sv ${shell} /bin/sh
    ln -s ${modules}/lib/modules /lib/modules

    for x in ${lib.concatStringsSep " " config.boot.initrd.kernelModules}; do
      modprobe $x
    done

    root=/dev/vda
    for o in $(cat /proc/cmdline); do
      case $o in
        systemConfig=*)
          set -- $(IFS==; echo $o)
          sysconfig=$2
          ;;
        root=*)
          set -- $(IFS==; echo $o)
          root=$2
          ;;
        netroot=*)
          set -- $(IFS==; echo $o)
          mkdir -pv /var/run /var/db
          sleep 5
          dhcpcd eth0 -c ${dhcpHook}
          tftp -g -r "$3" "$2"
          root=/root.squashfs
          ;;
      esac
    done

    mount -t tmpfs root /mnt/ -o size=6G || exec ${shell}
    chmod 755 /mnt/
    mkdir -p /mnt/nix/store/

    # make the store writeable
    mkdir -p /mnt/nix/.ro-store /mnt/nix/.overlay-store /mnt/nix/store
    mount $root /mnt/nix/.ro-store -t squashfs
    mount tmpfs -t tmpfs /mnt/nix/.overlay-store -o size=1G
    mkdir -pv /mnt/nix/.overlay-store/work /mnt/nix/.overlay-store/rw
    modprobe overlay
    mount -t overlay overlay -o lowerdir=/mnt/nix/.ro-store,upperdir=/mnt/nix/.overlay-store/rw,workdir=/mnt/nix/.overlay-store/work /mnt/nix/store

    exec env -i $(type -P switch_root) /mnt/ $sysconfig/init
    exec ${shell}
  '';
  initialRamdisk = pkgs.makeInitrd {
    contents = [ { object = bootStage1; symlink = "/init"; } ];
  };

in
{
  options = {
    boot.initrd.supportedFilesystems = mkOption {
      default = [ ];
      example = [ "btrfs" ];
      type = types.listOf types.str;
      description = "Names of supported filesystem types in the initial ramdisk.";
    };
    boot.initrd.extraUtilsCommands = mkOption {
      internal = true;
      default = "";
      type = types.lines;
      description = ''
        Shell commands to be executed in the builder of the
        extra-utils derivation.  This can be used to provide
        additional utilities in the initial ramdisk.
      '';
    };
    boot.initrd.extraUtilsCommandsTest = mkOption {
      internal = true;
      default = "";
      type = types.lines;
      description = ''
        Shell commands to be executed in the builder of the
        extra-utils derivation after patchelf has done its
        job.  This can be used to test additional utilities
        copied in extraUtilsCommands.
      '';
    };
    boot.initrd.postDeviceCommands = mkOption {
      default = "";
      type = types.lines;
      description = ''
        Shell commands to be executed immediately after stage 1 of the
        boot has loaded kernel modules and created device nodes in
        <filename>/dev</filename>.
      '';
    };
  };
  config = {
    system.build.bootStage1 = bootStage1;
    system.build.initialRamdisk = initialRamdisk;
    system.build.extraUtils = extraUtils;
    boot.initrd.extraUtilsCommands = extraUtilsCommands;
    boot.initrd.availableKernelModules = [ ];
    boot.initrd.kernelModules = [ "tun" "loop" "squashfs" "overlay"];
  };
}

{ stdenv, lib, fetchFromGitHub, autoreconfHook, util-linux, nukeReferences
, coreutils, perl, buildPackages
, configFile ? "all"

# Userspace dependencies
, zlib, libuuid, python3, attr, openssl
, libtirpc
, nfs-utils
, gawk, gnugrep, gnused, systemd
, smartmontools, sysstat, sudo
, pkg-config, installShellFiles

# Kernel dependencies
, kernel ? null
, rev, sha256
}:

with lib;
let
  buildKernelBuiltin = any (n: n == configFile) [ "builtin" ];
  buildKernelModules = any (n: n == configFile) [ "kernel" "all" ];
  buildUser = any (n: n == configFile) [ "user" "all" ];
  buildKernel = (buildKernelBuiltin) || (buildKernelModules);

  realConfigFile = if configFile == "builtin" then "kernel" else configFile;

  common = { version
    , sha256
    , extraPatches ? []
    , rev ? "zfs-${version}"
    , isUnstable ? false
    , incompatibleKernelVersion ? null }:
    if buildKernel &&
      (incompatibleKernelVersion != null) &&
        versionAtLeast kernel.version incompatibleKernelVersion then
       throw ''
         Linux v${kernel.version} is not yet supported by zfsonlinux v${version}.
         ${lib.optionalString (!isUnstable) "Try zfsUnstable or set the vpsAdminOS option boot.zfs.enableUnstable."}
       ''
    else stdenv.mkDerivation {
      name = "zfs-${configFile}-${version}${optionalString buildKernel "-${kernel.version}"}";

      src = fetchFromGitHub {
        inherit rev; inherit sha256; repo = "zfs"; owner = "vpsfreecz";
      };

      patches = extraPatches;

      postPatch = optionalString buildKernel ''
        patchShebangs scripts
        # The arrays must remain the same length, so we repeat a flag that is
        # already part of the command and therefore has no effect.
        substituteInPlace ./module/os/linux/zfs/zfs_ctldir.c \
          --replace '"/usr/bin/env", "umount"' '"${util-linux}/bin/umount", "-n"' \
          --replace '"/usr/bin/env", "mount"'  '"${util-linux}/bin/mount", "-n"'
      '' + optionalString buildUser ''
        substituteInPlace ./lib/libzfs/libzfs_mount.c --replace "/bin/umount"             "${util-linux}/bin/umount" \
                                                      --replace "/bin/mount"              "${util-linux}/bin/mount"
      	substituteInPlace ./lib/libshare/os/linux/nfs.c --replace "/usr/sbin/exportfs"    "${nfs-utils}/bin/exportfs"
        substituteInPlace ./config/user-systemd.m4    --replace "/usr/lib/modules-load.d" "$out/etc/modules-load.d"
        substituteInPlace ./config/zfs-build.m4       --replace "\$sysconfdir/init.d"     "$out/etc/init.d" \
                                                      --replace "/etc/default"            "$out/etc/default" \
                                                      --replace "/etc/bash_completion.d"  "$out/etc/bash_completion.d"
        [ -f ./etc/zfs/Makefile.am ] && \
          substituteInPlace ./etc/zfs/Makefile.am       --replace "\$(sysconfdir)"          "$out/etc"
        substituteInPlace ./cmd/zed/Makefile.am       --replace "\$(sysconfdir)"          "$out/etc"

        [ -f ./contrib/initramfs/hooks/Makefile.am ] && \
        substituteInPlace ./contrib/initramfs/hooks/Makefile.am \
          --replace "/usr/share/initramfs-tools/hooks" "$out/usr/share/initramfs-tools/hooks"
        [ -f ./contrib/initramfs/Makefile.am ] && \
        substituteInPlace ./contrib/initramfs/Makefile.am \
          --replace "/usr/share/initramfs-tools" "$out/usr/share/initramfs-tools"
        [ -f ./contrib/initramfs/scripts/Makefile.am ] && \
        substituteInPlace ./contrib/initramfs/scripts/Makefile.am \
          --replace "/usr/share/initramfs-tools/scripts" "$out/usr/share/initramfs-tools/scripts"
        [ -f ./contrib/initramfs/scripts/local-top/Makefile.am ] && \
        substituteInPlace ./contrib/initramfs/scripts/local-top/Makefile.am \
          --replace "/usr/share/initramfs-tools/scripts/local-top" "$out/usr/share/initramfs-tools/scripts/local-top"
        [ -f ./contrib/initramfs/scripts/Makefile.am ] && \
        substituteInPlace ./contrib/initramfs/scripts/Makefile.am \
          --replace "/usr/share/initramfs-tools/scripts" "$out/usr/share/initramfs-tools/scripts"
        [ -f ./contrib/initramfs/scripts/local-top/Makefile.am ] && \
        substituteInPlace ./contrib/initramfs/scripts/local-top/Makefile.am \
          --replace "/usr/share/initramfs-tools/scripts/local-top" "$out/usr/share/initramfs-tools/scripts/local-top"
        [ -f ./etc/systemd/system/Makefile.am ] && \
        substituteInPlace ./etc/systemd/system/Makefile.am \
          --replace '$(DESTDIR)$(systemdunitdir)' "$out"'$(DESTDIR)$(systemdunitdir)'

        [ -f ./contrib/initramfs/conf.d/Makefile.am ] && \
        substituteInPlace ./contrib/initramfs/conf.d/Makefile.am \
          --replace "/usr/share/initramfs-tools/conf.d" "$out/usr/share/initramfs-tools/conf.d"
        [ -f ./contrib/initramfs/conf-hooks.d/Makefile.am ] && \
        substituteInPlace ./contrib/initramfs/conf-hooks.d/Makefile.am \
          --replace "/usr/share/initramfs-tools/conf-hooks.d" "$out/usr/share/initramfs-tools/conf-hooks.d"

        [ -f ./etc/systemd/system/zfs-share.service.in ] && \
        substituteInPlace ./etc/systemd/system/zfs-share.service.in \
          --replace "/bin/rm " "${coreutils}/bin/rm "

        [ -f ./cmd/vdev_id/vdev_id ] && \
        substituteInPlace ./cmd/vdev_id/vdev_id \
          --replace "PATH=/bin:/sbin:/usr/bin:/usr/sbin" \
          "PATH=${makeBinPath [ coreutils gawk gnused gnugrep ]}"

        [ -f ./udev/rules.d/69-vdev.rules.in ] && \
        substituteInPlace ./udev/rules.d/69-vdev.rules.in \
	        --replace "@udevdir@/rules.d/69-vdev.rules" "pllm"
      '';

      nativeBuildInputs = [ autoreconfHook nukeReferences installShellFiles ]
        ++ optionals buildKernel (kernel.moduleBuildDependencies ++ [ perl ])
        ++ optional buildUser pkg-config;
      buildInputs = optionals buildUser [ zlib libuuid attr libtirpc python3 ]
        ++ optional buildUser openssl;

      # for zdb to get the rpath to libgcc_s, needed for pthread_cancel to work
      NIX_CFLAGS_LINK = "-lgcc_s";

      hardeningDisable = [ "fortify" "stackprotector" "pic" ];

      configureFlags = [
        "--enable-debug"
        "--with-config=${realConfigFile}"
	      "--with-tirpc=1"
        (withFeatureAs buildUser "python" python3.interpreter)
      ] ++ optionals buildUser [
        "--with-dracutdir=$(out)/lib/dracut"
        "--with-udevdir=$(out)/lib/udev"
        "--with-mounthelperdir=$(out)/bin"
        "--libexecdir=$(out)/libexec"
        "--sysconfdir=/etc"
        "--localstatedir=/var"
      ] ++ optionals buildKernelBuiltin [
        "--enable-linux-builtin"
      ] ++ optionals buildKernel ([
        "--with-linux=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
        "--with-linux-obj=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
      ] ++ kernel.makeFlags);

      makeFlags = optionals buildKernel kernel.makeFlags;

      enableParallelBuilding = true;

      buildPhase = optionalString (buildKernelBuiltin) ''
      '';

      installPhase = optionalString (buildKernelBuiltin) ''
        mkdir -p $out
        cp -r ./* $out
      '';

      installFlags = [
        "sysconfdir=\${out}/etc"
        "hooksdir=\${out}/usr/share/initramfs-tools/hooks"
        "scriptsdir=\${out}/usr/share/initramfs-tools/scripts"
        "localtopdir=\${out}/usr/share/initramfs-tools/scripts/local-top"
        "initrddir=\${out}/usr/share/initramfs-tools"
        "DEFAULT_INIT_DIR=\${out}/etc/init.d"
        "DEFAULT_INITCONF_DIR=\${out}/default"
        "INSTALL_MOD_PATH=\${out}"
      ];

      postInstall = optionalString buildKernelModules ''
        # Add reference that cannot be detected due to compressed kernel module
        mkdir -p "$out/nix-support"
        echo "${util-linux}" >> "$out/nix-support/extra-refs"
      '' + optionalString buildUser ''
        rm -rf $out/share/zfs/zfs-tests
        # Add Bash completions.
        installShellCompletion etc/bash_completion.d/*
      '';

      postFixup = ''
        path="PATH=${makeBinPath [ coreutils gawk gnused gnugrep util-linux smartmontools sysstat sudo ]}"
        for i in $out/libexec/zfs/zpool.d/*; do
          sed -i "2i$path" $i
        done
      '' + optionalString buildUser ''
        patchShebangs $out/bin
      '';

      outputs = [ "out" ] ++ optionals buildUser [ "dev" ];

      meta = {
        description = "ZFS Filesystem Linux Kernel module";
        longDescription = ''
          ZFS is a filesystem that combines a logical volume manager with a
          Copy-On-Write filesystem with data integrity detection and repair,
          snapshotting, cloning, block devices, deduplication, and more.
        '';
        homepage = https://zfsonlinux.org/;
        license = licenses.cddl;
        platforms = platforms.linux;
      };
    };
in {
  zfsStable = common {
    version = "2.0-vpsadminos";
    inherit rev; inherit sha256;
  };
}

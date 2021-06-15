{ stdenv, fetchFromGitHub, autoreconfHook, utillinux, nukeReferences, coreutils
, perl, buildPackages
, configFile ? "all"

# Userspace dependencies
, zlib, libuuid, python3, attr, openssl
, libtirpc
, nfs-utils
, gawk, gnugrep, gnused, systemd
, smartmontools, sysstat, sudo
, pkgconfig

# Kernel dependencies
, kernel ? null
}:

with stdenv.lib;
let
  buildKernel = any (n: n == configFile) [ "kernel" "all" ];
  buildUser = any (n: n == configFile) [ "user" "all" ];

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
         ${stdenv.lib.optionalString (!isUnstable) "Try zfsUnstable or set the vpsAdminOS option boot.zfs.enableUnstable."}
       ''
    else stdenv.mkDerivation {
      name = "zfs-${configFile}-${version}${optionalString buildKernel "-${kernel.version}"}";

      src = fetchFromGitHub {
        owner = "vpsfreecz";
        repo = "zfs";
        inherit rev sha256;
      };

      patches = extraPatches;

      postPatch = optionalString buildKernel ''
        patchShebangs scripts
        # The arrays must remain the same length, so we repeat a flag that is
        # already part of the command and therefore has no effect.
        substituteInPlace ./module/os/linux/zfs/zfs_ctldir.c \
          --replace '"/usr/bin/env", "umount"' '"${utillinux}/bin/umount", "-n"' \
          --replace '"/usr/bin/env", "mount"'  '"${utillinux}/bin/mount", "-n"'
      '' + optionalString buildUser ''
        substituteInPlace ./lib/libzfs/libzfs_mount.c --replace "/bin/umount"             "${utillinux}/bin/umount" \
                                                      --replace "/bin/mount"              "${utillinux}/bin/mount"
	substituteInPlace ./lib/libshare/os/linux/nfs.c --replace "/usr/sbin/exportfs"    "${nfs-utils}/bin/exportfs"
        substituteInPlace ./config/user-systemd.m4    --replace "/usr/lib/modules-load.d" "$out/etc/modules-load.d"
        substituteInPlace ./config/zfs-build.m4       --replace "\$sysconfdir/init.d"     "$out/etc/init.d" \
                                                      --replace "/etc/default"            "$out/etc/default"
        substituteInPlace ./etc/zfs/Makefile.am       --replace "\$(sysconfdir)"          "$out/etc"
        substituteInPlace ./cmd/zed/Makefile.am       --replace "\$(sysconfdir)"          "$out/etc"

        substituteInPlace ./contrib/initramfs/hooks/Makefile.am \
          --replace "/usr/share/initramfs-tools/hooks" "$out/usr/share/initramfs-tools/hooks"
        substituteInPlace ./contrib/initramfs/Makefile.am \
          --replace "/usr/share/initramfs-tools" "$out/usr/share/initramfs-tools"
        substituteInPlace ./contrib/initramfs/scripts/Makefile.am \
          --replace "/usr/share/initramfs-tools/scripts" "$out/usr/share/initramfs-tools/scripts"
        substituteInPlace ./contrib/initramfs/scripts/local-top/Makefile.am \
          --replace "/usr/share/initramfs-tools/scripts/local-top" "$out/usr/share/initramfs-tools/scripts/local-top"
        substituteInPlace ./contrib/initramfs/scripts/Makefile.am \
          --replace "/usr/share/initramfs-tools/scripts" "$out/usr/share/initramfs-tools/scripts"
        substituteInPlace ./contrib/initramfs/scripts/local-top/Makefile.am \
          --replace "/usr/share/initramfs-tools/scripts/local-top" "$out/usr/share/initramfs-tools/scripts/local-top"
        substituteInPlace ./etc/systemd/system/Makefile.am \
          --replace '$(DESTDIR)$(systemdunitdir)' "$out"'$(DESTDIR)$(systemdunitdir)'

        substituteInPlace ./contrib/initramfs/conf.d/Makefile.am \
          --replace "/usr/share/initramfs-tools/conf.d" "$out/usr/share/initramfs-tools/conf.d"
        substituteInPlace ./contrib/initramfs/conf-hooks.d/Makefile.am \
          --replace "/usr/share/initramfs-tools/conf-hooks.d" "$out/usr/share/initramfs-tools/conf-hooks.d"

        substituteInPlace ./etc/systemd/system/zfs-share.service.in \
          --replace "/bin/rm " "${coreutils}/bin/rm "

        substituteInPlace ./cmd/vdev_id/vdev_id \
          --replace "PATH=/bin:/sbin:/usr/bin:/usr/sbin" \
          "PATH=${makeBinPath [ coreutils gawk gnused gnugrep ]}"

        substituteInPlace ./udev/rules.d/69-vdev.rules.in \
	  --replace "@udevdir@/rules.d/69-vdev.rules" "pllm"
      '';

      nativeBuildInputs = [ autoreconfHook nukeReferences ]
        ++ optionals buildKernel (kernel.moduleBuildDependencies ++ [ perl ])
        ++ optional buildUser pkgconfig;
      buildInputs = optionals buildUser [ zlib libuuid attr libtirpc python3 ]
        ++ optional buildUser openssl;

      # for zdb to get the rpath to libgcc_s, needed for pthread_cancel to work
      NIX_CFLAGS_LINK = "-lgcc_s";

      hardeningDisable = [ "fortify" "stackprotector" "pic" ];

      configureFlags = [
        "--with-config=${configFile}"
	"--with-tirpc=1"
        (withFeatureAs buildUser "python" python3.interpreter)
      ] ++ optionals buildUser [
        "--with-dracutdir=$(out)/lib/dracut"
        "--with-udevdir=$(out)/lib/udev"
        "--with-mounthelperdir=$(out)/bin"
        "--libexecdir=$(out)/libexec"
        "--sysconfdir=/etc"
        "--localstatedir=/var"
      ] ++ optionals buildKernel ([
        "--with-linux=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
        "--with-linux-obj=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
      ] ++ kernel.makeFlags);

      makeFlags = optionals buildKernel kernel.makeFlags;

      enableParallelBuilding = true;

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

      postInstall = optionalString buildKernel ''
        # Add reference that cannot be detected due to compressed kernel module
        mkdir -p "$out/nix-support"
        echo "${utillinux}" >> "$out/nix-support/extra-refs"
      '' + optionalString buildUser ''
        rm -rf $out/share/zfs/zfs-tests
        # Add Bash completions.
        install -v -m444 -D -t $out/share/bash-completion/completions contrib/bash_completion.d/zfs
        (cd $out/share/bash-completion/completions; ln -s zfs zpool)
      '';

      postFixup = ''
        path="PATH=${makeBinPath [ coreutils gawk gnused gnugrep utillinux smartmontools sysstat sudo ]}"
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

    rev = "015038697907b47e869c230d70ebe1720c658a03";
    sha256 = "05x2h447bm7mxx0cwfbd59sn6cpw42qnizbkg14i9i9dp98kqlbf";
  };
}

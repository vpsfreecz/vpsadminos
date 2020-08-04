{ stdenv, fetchFromGitHub, autoreconfHook, utillinux, nukeReferences, coreutils
, perl, buildPackages
, configFile ? "all"

# Userspace dependencies
, zlib, libuuid, python3, attr, openssl
, libtirpc
, nfs-utils
, gawk, gnugrep, gnused, systemd
, smartmontools, sysstat, sudo

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
        patchShebangs ./scripts
        # The arrays must remain the same length, so we repeat a flag that is
        # already part of the command and therefore has no effect.
        substituteInPlace ./module/os/linux/zfs/zfs_ctldir.c --replace '"/usr/bin/env", "umount"' '"${utillinux}/bin/umount", "-n"' \
                                                             --replace '"/usr/bin/env", "mount"'  '"${utillinux}/bin/mount", "-n"'
      '' + optionalString buildUser ''
        substituteInPlace ./lib/libzfs/os/linux/libzfs_mount_os.c --replace "/bin/umount"             "${utillinux}/bin/umount" \
                                                                  --replace "/bin/mount"              "${utillinux}/bin/mount"
        substituteInPlace ./lib/libshare/os/linux/nfs.c           --replace "/usr/sbin/exportfs"      "${nfs-utils}/bin/exportfs"
        substituteInPlace ./cmd/vdev_id/vdev_id \
          --replace "PATH=/bin:/sbin:/usr/bin:/usr/sbin" \
          "PATH=${makeBinPath [ coreutils gawk gnused gnugrep systemd ]}"
      '' + optionalString stdenv.hostPlatform.isMusl ''
        substituteInPlace config/user-libtirpc.m4 \
          --replace /usr/include/tirpc ${libtirpc}/include/tirpc
      '';

      nativeBuildInputs = [ autoreconfHook nukeReferences ]
        ++ optionals buildKernel (kernel.moduleBuildDependencies ++ [ perl ]);
      buildInputs = optionals buildUser [ zlib libuuid attr ]
        ++ optionals (buildUser) [ openssl python3 ]
        ++ optional stdenv.hostPlatform.isMusl libtirpc;

      # for zdb to get the rpath to libgcc_s, needed for pthread_cancel to work
      NIX_CFLAGS_LINK = "-lgcc_s";

      hardeningDisable = [ "fortify" "stackprotector" "pic" ];

      configureFlags = [
        "--with-config=${configFile}"
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
      '';

      outputs = [ "out" ] ++ optionals buildUser [ "lib" "dev" ];

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
    version = "0.8.99.vpsadminos";

    rev = "b6208d8318d6b2515825f7d35c86a7f7f61f563e";
    sha256 = "sha256:158q20fj94r8npl0m4nrrgiiidgrkqqrczirbmjng7f73kc2jzgw";
  };
}

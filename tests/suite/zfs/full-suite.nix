import ../../make-test.nix (
  { pkgs }:
  {
    name = "zfs-full-suite";

    description = ''
      Run OpenZFS test suite inside vpsAdminOS test-runner VM.

      This test is intentionally not tagged as `ci`. Run it explicitly using
      tag `zfs-full`.
    '';

    tags = [ "zfs-full" ];

    labels = {
      component = "zfs";
      runtime = "long";
      gate = "manual";
    };

    machine =
      (import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config =
          {
            config,
            pkgs,
            lib,
            ...
          }:
          let
            zfsVmMemoryEnv = builtins.getEnv "VPSADMINOS_ZFS_FULL_VM_MEMORY";
            zfsVmCpusEnv = builtins.getEnv "VPSADMINOS_ZFS_FULL_VM_CPUS";
            zfsUseBuiltinEnv = builtins.getEnv "VPSADMINOS_ZFS_FULL_USE_BUILTIN";
            localZfsStageEnv = builtins.getEnv "VPSADMINOS_LOCAL_ZFS_STAGE";
            localZfsUserSourceEnv = builtins.getEnv "VPSADMINOS_ZFS_FULL_USER_SOURCE";
            localZfsStage = if localZfsStageEnv == "" then null else /. + localZfsStageEnv;
            localZfsUserOut = if localZfsStage == null then null else localZfsStage + "/user/out";
            zfsVmMemory = if zfsVmMemoryEnv != "" then lib.toInt zfsVmMemoryEnv else 12288;
            zfsVmCpus = if zfsVmCpusEnv != "" then lib.toInt zfsVmCpusEnv else 4;
            zfsUseBuiltin = zfsUseBuiltinEnv == "1";
            useLocalZfsUser = !zfsUseBuiltin && localZfsUserOut != null && builtins.pathExists localZfsUserOut;
            adaptedLocalZfsUser =
              if useLocalZfsUser then
                import ../../../os/lib/dev/local-zfs-package.nix {
                  inherit pkgs lib;
                  stage = localZfsStage;
                  kind = "user";
                }
              else
                null;
            kernelPackages = import ../../../os/packages/linux/packages.nix {
              inherit
                config
                pkgs
                lib
                ;
            };
            zfsTestPython = pkgs.python3.withPackages (
              ps: with ps; [
                cffi
                distlib
                packaging
                setuptools
              ]
            );

            zfsTestPostInstall = ''
              # vpsAdminOS exposes most commands under /run/current-system/sw.
              substituteInPlace $out/usr/share/initramfs-tools/scripts/zfs-tests.sh \
                --replace 'SYSTEM_DIRS="/usr/local/bin /usr/local/sbin"' \
                          'SYSTEM_DIRS="/run/wrappers/bin /usr/local/bin /usr/local/sbin /run/current-system/sw/bin /run/current-system/sw/sbin"'
              # Single-test mode (`-t`) writes an ad-hoc runfile with a fixed
              # 10-minute timeout. Allow slow VM stress cases up to one hour.
              substituteInPlace $out/usr/share/initramfs-tools/scripts/zfs-tests.sh \
                --replace 'timeout = 600' 'timeout = 3600'
              # A hook selected as the single test must not also run as its own
              # group hook in the generated ad-hoc runfile.
              substituteInPlace $out/usr/share/initramfs-tools/scripts/zfs-tests.sh \
                --replace-fail \
                  'SINGLETESTFILE="''${SINGLETEST##*/}"' \
                  $'SINGLETESTFILE="''${SINGLETEST##*/}"\ncase "$SINGLETESTFILE" in "$SETUPSCRIPT"|"$SETUPSCRIPT.ksh") SETUPSCRIPT= ;; esac\ncase "$SINGLETESTFILE" in "$CLEANUPSCRIPT"|"$CLEANUPSCRIPT.ksh") CLEANUPSCRIPT= ;; esac'

              # Copied local stages retain their original absolute paths in
              # common.sh. Retarget the test driver to this adjusted output.
              sed -i \
                -e "s|^export BIN_DIR=.*|export BIN_DIR=$out/bin|" \
                -e "s|^export SBIN_DIR=.*|export SBIN_DIR=$out/sbin|" \
                -e "s|^export LIBEXEC_DIR=.*|export LIBEXEC_DIR=$out/libexec/zfs|" \
                -e "s|^export ZTS_DIR=.*|export ZTS_DIR=$out/share/zfs|" \
                -e "s|^export SCRIPT_DIR=.*|export SCRIPT_DIR=$out/share/zfs|" \
                $out/share/zfs/common.sh

              # The external stage records its build-shell Python path, which
              # is not an input of the adapted Nix package or its VM closure.
              pyzfs_test=$out/share/zfs/zfs-tests/tests/functional/pyzfs/pyzfs_unittest.ksh
              sed -i -E \
                "s|^/nix/store/[^[:space:]]+/bin/python3[^[:space:]]* -m unittest|PATH=${
                  lib.makeBinPath [ pkgs.binutils ]
                }\''${PATH:+:\$PATH} LD_LIBRARY_PATH=$out/lib\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH} PYTHONPATH=$out/lib/python${pkgs.python3.pythonVersion}/site-packages ${zfsTestPython}/bin/python3 -m unittest|" \
                "$pyzfs_test"
              grep -Fq \
                "PATH=${
                  lib.makeBinPath [ pkgs.binutils ]
                }\''${PATH:+:\$PATH} LD_LIBRARY_PATH=$out/lib\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH} PYTHONPATH=$out/lib/python${pkgs.python3.pythonVersion}/site-packages ${zfsTestPython}/bin/python3 -m unittest" \
                "$pyzfs_test"

              # xattrtest's default post-phase hook is the FHS-only
              # /bin/true. Supply the packaged coreutils path for every call.
              mv $out/share/zfs/zfs-tests/bin/xattrtest \
                $out/share/zfs/zfs-tests/bin/xattrtest.real
              cat > $out/share/zfs/zfs-tests/bin/xattrtest <<EOF
              #!${pkgs.runtimeShell}
              exec "$out/share/zfs/zfs-tests/bin/xattrtest.real" -t \
                "${pkgs.coreutils}/bin/true" "\$@"
              EOF
              chmod +x $out/share/zfs/zfs-tests/bin/xattrtest

              # Coreutils dispatches its multicall binary by argv[0], so retain
              # the ls basename while testing execution from a ZFS dataset.
              substituteInPlace $out/share/zfs/zfs-tests/tests/functional/exec/exec_001_pos.ksh \
                --replace-fail '$TESTDIR/myls' '$TESTDIR/ls'

              # The auto-replace cases use an FHS-only path even though
              # util-linux is already part of the guest's test closure.
              for test in auto_replace_001_pos.ksh auto_replace_002_pos.ksh; do
                substituteInPlace \
                  "$out/share/zfs/zfs-tests/tests/functional/fault/$test" \
                  --replace-fail '/usr/sbin/wipefs' '${pkgs.util-linux}/bin/wipefs'
              done

              # Keep the namespace child alive so missing FHS tools cannot
              # turn mapping and delegation assertions into unsupported skips.
              for test in \
                idmap_mount/idmap_mount_003 \
                idmap_mount/idmap_mount_004 \
                idmap_mount/idmap_mount_005 \
                user_namespace/user_namespace_002 \
                user_namespace/user_namespace_003; do
                substituteInPlace \
                  "$out/share/zfs/zfs-tests/tests/functional/$test.ksh" \
                  --replace-fail '/usr/bin/sleep' '${pkgs.coreutils}/bin/sleep'
              done

              # This VM already runs the real NFS server. Supply the missing
              # Linux fixtures for the unprivileged share/unshare bodies; keep
              # the attempted ZFS operations unprivileged and observe exports
              # with sudo, rather than mistaking unreadable etab for no share.
              misc_tests=$out/share/zfs/zfs-tests/tests/functional/cli_user/misc
              substituteInPlace "$misc_tests/setup.ksh" \
                --replace-fail 'if is_global_zone && ! is_linux' 'if is_global_zone'
              for test in zfs_share_001_neg zfs_unshare_001_neg; do
                substituteInPlace "$misc_tests/$test.ksh" \
                  --replace-fail 'if is_linux || is_freebsd; then' 'if is_freebsd; then' \
                  --replace-fail 'verify_runnable "global"' \
                  $'verify_runnable "global"\nlog_mustnot test "$(id -u)" -eq 0\nfunction is_shared_linux {\n  typeset exports\n  exports=$(sudo -n exportfs -s) || log_fail "cannot read exports"\n  printf "%s\\n" "$exports" | awk -v fs="$1" \'$1 == fs { found=1 } END { exit !found }\'\n}'
              done
              # Both error messages were unconditional, so the skipped body
              # could never reach its permission check even with valid setup.
              substituteInPlace "$misc_tests/zfs_unshare_001_neg.ksh" \
                --replace-fail \
                  $'log_mustnot not_shared $TESTDIR/shared\nlog_fail "$TESTPOOL/$TESTFS/shared was not shared initially at all!"' \
                  'log_must is_shared $TESTDIR/shared' \
                --replace-fail \
                  $'log_mustnot not_shared $TESTDIR/shared\nlog_fail "$TESTPOOL/$TESTFS/shared was actually unshared!"' \
                  'log_must is_shared $TESTDIR/shared'

              # Historical slowness/hang reports are not platform exclusions.
              # Run these bodies under the existing native runner deadlines,
              # preserving their assertions and reporting any real failure.
              functional=$out/share/zfs/zfs-tests/tests/functional
              # Linux libshare owns zfs.exports, not exportfs-managed legacy
              # shares. An already-off property must leave those exports
              # alone. Reset them explicitly before the next share scenario.
              # Bulk unshare calls exportfs -ra, which synchronizes etab with
              # exports files. Prove that transient exports are removed by
              # that command alone, then use a separate legacy exports file
              # for the original bulk-unshare preservation assertion.
              substituteInPlace "$functional/cli_root/zfs_unshare/zfs_unshare_002_pos.ksh" \
                --replace-fail ${lib.escapeShellArg ''log_unsupported "zfs set sharenfs=off won't unshare if already off"''} \
                  'log_note "Checking Linux exportfs-owned legacy shares"' \
                --replace-fail ${lib.escapeShellArg "not_shared \${mntp_fs[i]} ||"} \
                  ${lib.escapeShellArg "is_shared \${mntp_fs[i]} ||"} \
                --replace-fail ${lib.escapeShellArg ''log_fail "'zfs set sharenfs=off' unshares file system failed."''} \
                  ${lib.escapeShellArg ''
                    log_fail "sharenfs=off removed a legacy export"
                    log_must unshare_nfs ''${mntp_fs[i]}
                    not_shared ''${mntp_fs[i]} || log_fail "exportfs failed to remove legacy export"
                  ''} \
                --replace-fail $'function cleanup\n{' \
                  ${lib.escapeShellArg ''
                    legacy_exports=
                    function cleanup
                    {
                        if [[ -n $legacy_exports ]]; then
                            log_must rm -f "$legacy_exports"
                        fi
                  ''} \
                --replace-fail 'log_must zfs unshare -a' \
                  ${lib.escapeShellArg ''
                    log_note "exportfs -ra drops transient exports absent from exports files"
                    log_must exportfs -ra
                    i=0
                    while (( i < ''${#mntp_fs[*]} )); do
                        not_shared ''${mntp_fs[i]} || log_fail "transient export survived resync"
                        ((i = i + 2))
                    done

                    log_must mkdir -p /etc/exports.d
                    log_must test ! -e /etc/exports.d/zts-legacy.exports
                    legacy_exports=/etc/exports.d/zts-legacy.exports
                    i=0
                    while (( i < ''${#mntp_fs[*]} )); do
                        log_must eval "printf '%s *(rw,sync,no_subtree_check)\n' ''${mntp_fs[i]} >> $legacy_exports"
                        ((i = i + 2))
                    done
                    log_must exportfs -ra
                    i=0
                    while (( i < ''${#mntp_fs[*]} )); do
                        is_shared ''${mntp_fs[i]} || log_fail "configured legacy export missing"
                        ((i = i + 2))
                    done
                    log_must zfs unshare -a
                  ''}
              substituteInPlace "$functional/cli_root/zpool_import/zpool_import_missing_003_pos.ksh" \
                --replace-fail 'log_unsupported "Test case may be slow"' \
                  'log_note "Exercising historical slow import case (issue 6839)"' \
                --replace-fail 'read -r checksum1 < <(cksum $MYTESTFILE)' \
                  'read -r checksum1 _ < <(cksum $MYTESTFILE)'
              substituteInPlace "$functional/pool_checkpoint/checkpoint_discard_busy.ksh" \
                --replace-fail 'log_unsupported "Skipping, issue https://github.com/openzfs/zfs/issues/12053"' \
                  'log_note "Exercising historical busy-discard case (issue 12053)"' \
                --replace-fail \
                  $'function test_cleanup\n{\n\t# reset to original value\n\tlog_must restore_tunable SPA_DISCARD_MEMORY_LIMIT' \
                  $'function test_cleanup\n{\n\t# The successful body already consumes the saved tunable file.\n\tif [[ -e $TEST_BASE_DIR/tunable-SPA_DISCARD_MEMORY_LIMIT ]]; then\n\t\tlog_must restore_tunable SPA_DISCARD_MEMORY_LIMIT\n\tfi' \
                --replace-fail 'log_must save_tunable SPA_DISCARD_MEMORY_LIMIT' \
                  $'original_discard_limit=$(get_tunable SPA_DISCARD_MEMORY_LIMIT)\nlog_must save_tunable SPA_DISCARD_MEMORY_LIMIT' \
                --replace-fail $'log_must restore_tunable SPA_DISCARD_MEMORY_LIMIT\n\nnested_wait_discard_finish' \
                  $'log_must restore_tunable SPA_DISCARD_MEMORY_LIMIT\nlog_must test "$(get_tunable SPA_DISCARD_MEMORY_LIMIT)" = "$original_discard_limit"\n\nnested_wait_discard_finish'
              substituteInPlace "$functional/rsend/rsend_008_pos.ksh" \
                --replace-fail 'log_unsupported "Occasionally hangs"' \
                  'log_note "Exercising historical promoted-send case (issue 6066)"' \
                --replace-fail 'log_must eval "zfs send -R $POOL@final > $BACKDIR/pool-final-R"' \
                  ${lib.escapeShellArg ''
                    log_note "Starting recursive send after promotion"
                    zfs send -R $POOL@final > $BACKDIR/pool-final-R &
                    send_pid=$!
                    (
                      sleep 30
                      if kill -0 "$send_pid" 2>/dev/null; then
                        {
                          date -Is
                          ps -p "$send_pid" -o pid,ppid,stat,etime,time,wchan,args
                          cat /proc/$send_pid/stat /proc/$send_pid/stack
                          zfs list -r -t all -o name,origin,createtxg $POOL
                          ${pkgs.gdb}/bin/gdb -q -nx -batch \
                            -ex 'set pagination off' -ex 'thread apply all bt' \
                            -ex 'info sharedlibrary' -ex 'x/16i $pc' \
                            -ex detach -p "$send_pid"
                        } 2>&1 | ${pkgs.coreutils}/bin/tee /run/osvm/shared-dir/zfs-full-suite/promoted-send-diagnostics.log
                      fi
                    ) &
                    diagnostic_pid=$!
                    wait "$send_pid"
                    send_status=$?
                    wait "$diagnostic_pid"
                    log_must test "$send_status" -eq 0
                  ''}
              # Bound this already reproduced stall while collecting its
              # first semantic checkpoint, rather than repeating a silent hour.
              substituteInPlace $out/usr/share/initramfs-tools/scripts/zfs-tests.sh \
                --replace-fail 'timeout = 3600' \
                  'timeout = $(case "$SINGLETEST" in */rsend_008_pos.ksh) echo 300 ;; *) echo 3600 ;; esac)'

              # OpenZFS 2.3.8 predates upstream 6f17052743, which makes the
              # L2ARC wrap test's intended write volume deterministic.
              substituteInPlace $out/share/zfs/zfs-tests/tests/functional/cache/cache_012_pos.ksh \
                --replace-fail \
                  'log_must zfs set relatime=off $TESTPOOL' \
                  $'log_must zfs set relatime=off $TESTPOOL\nlog_must zfs set compression=off $TESTPOOL'

              # ksh's [ builtin does not reliably check the escaped && chain.
              # Keep the busy writer off files retained by either rollback
              # target so valid concurrent writes cannot race these checks.
              substituteInPlace $out/share/zfs/zfs-tests/tests/functional/cli_root/zfs_rollback/zfs_rollback_common.kshlib \
                --replace-fail \
                  'log_must [ $sum0 = $origsum \&\& $sum1 = $origsum \&\& sum2 = $origsum ]' \
                  $'log_must [ "$sum0" = "$origsum" ]\n\t\t\tlog_must [ "$sum1" = "$origsum" ]\n\t\t\tlog_must [ "$sum2" = "$origsum" ]' \
                --replace-fail \
                  'log_must [ $sum0 = $origsum \&\& $sum1 = $origsum ]' \
                  $'log_must [ "$sum0" = "$origsum" ]\n\t\t\tlog_must [ "$sum1" = "$origsum" ]' \
                --replace-fail \
                  'log_must [ $sum0 = $origsum ]' \
                  'log_must [ "$sum0" = "$origsum" ]' \
                --replace-fail 'of=$dir/$TESTFILE1 &' 'of=$dir/$TESTFILE2 &'

              # Full-suite runfiles also inherit a 10-minute default timeout.
              # Override slow groups to avoid false KILLED results.
              awk '
                { print }
                /^\[tests\/functional\/alloc_class\]$/ { print "timeout = 1800" }
                /^\[tests\/functional\/cache\]$/ { print "timeout = 1800" }
                /^\[tests\/functional\/cli_root\/zfs_rollback\]$/ { print "timeout = 1800" }
                /^\[tests\/functional\/cli_root\/zfs_share\]$/ { print "timeout = 3600" }
                /^\[tests\/functional\/cli_root\/zpool_upgrade\]$/ { print "timeout = 3600" }
                /^\[tests\/functional\/cli_root\/zpool_prefetch\]$/ { print "timeout = 1800" }
                /^\[tests\/functional\/direct\]$/ { print "timeout = 1800" }
                /^\[tests\/functional\/mv_files\]$/ { print "timeout = 1800" }
                /^\[tests\/functional\/rsend\]$/ { print "timeout = 1800" }
              ' $out/share/zfs/runfiles/common.run > $out/share/zfs/runfiles/common.run.new
              mv $out/share/zfs/runfiles/common.run.new $out/share/zfs/runfiles/common.run

              awk '
                { print }
                /^\[tests\/functional\/direct:Linux\]$/ { print "timeout = 1800" }
              ' $out/share/zfs/runfiles/linux.run > $out/share/zfs/runfiles/linux.run.new
              mv $out/share/zfs/runfiles/linux.run.new $out/share/zfs/runfiles/linux.run

              # Some test helper binaries are optional in our build, don't report
              # them as missing when they are not installed.
              if [ ! -x "$out/share/zfs/zfs-tests/bin/devname2devid" ]; then
                sed -i '/^[[:space:]]*devname2devid$/d' \
                  "$out/share/zfs/zfs-tests/include/commands.cfg"
              fi

              if [ ! -x "$out/share/zfs/zfs-tests/bin/mmap_libaio" ]; then
                sed -i '/^[[:space:]]*mmap_libaio$/d' \
                  "$out/share/zfs/zfs-tests/include/commands.cfg"
              fi
            '';

            # Keep OpenZFS test-suite files in the userspace package for this test only.
            zfsUserWithTests =
              if useLocalZfsUser then
                pkgs.runCommand "zfs-user-local-dev-with-tests" { } ''
                  mkdir -p "$out"
                  cp -a --no-preserve=ownership ${adaptedLocalZfsUser}/. "$out"/
                  chmod -R u+w "$out"
                  for script in "$out"/libexec/zfs/zpool.d/*; do
                    sed -i "2iPATH=${
                      lib.makeBinPath [
                        pkgs.coreutils
                        pkgs.gawk
                        pkgs.gnused
                        pkgs.gnugrep
                        pkgs.util-linux
                        pkgs.smartmontools
                        pkgs.sysstat
                        pkgs.sudo
                      ]
                    }" "$script"
                  done
                  ${zfsTestPostInstall}
                ''
              else
                (kernelPackages.genZfsUserPackage config.boot.kernelVersion).overrideAttrs (old: {
                  # A source-only userspace repair can be exercised against
                  # the pinned module without changing production pins.
                  src = if localZfsUserSourceEnv == "" then old.src else lib.cleanSource (/. + localZfsUserSourceEnv);
                  # Exercise optional upstream test bodies in this test-only
                  # package, without adding PAM to the production ZFS build.
                  buildInputs = (old.buildInputs or [ ]) ++ [
                    pkgs.libaio
                    pkgs.pam
                  ];
                  configureFlags =
                    lib.filter (flag: !(lib.hasPrefix "--with-python=" flag)) (old.configureFlags or [ ])
                    ++ [
                      "--with-python=${zfsTestPython}/bin/python3"
                      "--enable-pyzfs"
                      "--enable-pam"
                    ];
                  postInstall =
                    (lib.replaceStrings
                      [ "rm -rf $out/share/zfs/zfs-tests" ]
                      [ "echo 'keeping zfs-tests for zfs-full-suite'" ]
                      (old.postInstall or "")
                    )
                    + zfsTestPostInstall
                    + ''
                      test -x "$out/share/zfs/zfs-tests/bin/mmap_libaio"
                      test -f "$out/lib/security/pam_zfs_key.so"
                    '';
                });
          in
          {
            # Keep bisect/repro runs fast by default, while allowing release
            # gates to test the shipped built-in ZFS kernel closure.
            boot.zfsBuiltin = lib.mkForce zfsUseBuiltin;
            # local-dev-qemu selects the raw staged userspace with mkForce.
            # This test's wrapped package must win so it retains and adjusts
            # the exact staged test suite rather than falling back to the pin.
            boot.zfsUserPackage =
              if useLocalZfsUser then lib.mkOverride 40 zfsUserWithTests else lib.mkForce zfsUserWithTests;
            # Bind the runner to the adjusted test package explicitly. The
            # system PATH can also contain the raw local-stage userspace.
            environment.etc."zfs-full-suite-root".text = toString zfsUserWithTests;
            # Prevent fd0 probing noise/stalls during long ZFS test runs.
            boot.blacklistedKernelModules = [ "floppy" ];
            # The production kernel disables implicit module autoloading. The
            # suite uses dm-crypt and XTS for LUKS, ext4 for its scratch disk,
            # ext2 for several zvol mount tests, and XFS for mount_loopback, so
            # load them explicitly.
            boot.kernelModules = [
              "dm-crypt"
              "ext2"
              "ext4"
              "xfs"
              "xts"
            ];
            boot.kernelParams = [ "floppy=off" ];
            # Imported fixture pools must remain unchanged while zpool_upgrade
            # compares their complete pre/post-upgrade file checksums.
            services.zfs.vdevlog.enable = lib.mkForce false;
            services.nfs.server.enable = true;
            # ZFS's protocol-specific unshare body requires real Samba
            # usershares as well as NFS. Bind this test-only server to loopback.
            environment.etc."samba/smb.conf".text = ''
              [global]
              interfaces = lo
              bind interfaces only = yes
              smb ports = 445
              security = user
              map to guest = Bad User
              usershare path = /var/lib/samba/usershares
              usershare max shares = 100
              usershare owner only = no
              usershare allow guests = yes
              load printers = no
              disable spoolss = yes
            '';
            runit.services.zfs-test-smb = {
              run = ''
                mkdir -p /var/lib/samba/usershares /var/lib/samba/private \
                  /var/cache/samba /var/lock/samba /var/run/samba /var/log/samba
                chmod 0700 /var/lib/samba/private
                chmod 1770 /var/lib/samba/usershares
                exec ${pkgs.samba}/bin/smbd --foreground --no-process-group \
                  --debug-stdout --configfile=/etc/samba/smb.conf
              '';
            };
            boot.qemu = {
              memory = lib.mkForce zfsVmMemory;
              cpus = lib.mkForce zfsVmCpus;
              cpu = {
                cores = lib.mkForce zfsVmCpus;
                threads = lib.mkForce 1;
                sockets = lib.mkForce 1;
              };
            };

            # Upstream io_uring probes /boot/config-$(uname -r). Expose the
            # actual kernel build configuration instead of skipping a feature
            # which is enabled, or fabricating a CONFIG_IO_URING=y marker.
            environment.etc."zfs-test/kernel-config".source = config.boot.kernelPackage.configfile;

            # zfs-tests.sh requires ksh and passwordless sudo for the run user.
            environment.systemPackages = [
              pkgs.attr
              pkgs.bash
              pkgs.bc
              pkgs.binutils
              pkgs.cryptsetup
              pkgs.e2fsprogs
              pkgs.file
              pkgs.fio
              pkgs.getent
              pkgs.jq
              pkgs.ksh
              pkgs.lvm2
              pkgs.lsscsi
              pkgs.openssl
              pkgs.pamtester
              pkgs.parted
              pkgs.pax
              pkgs.python3
              pkgs.samba
              pkgs.sudo
              pkgs.util-linux
              pkgs.xxHash
              pkgs.xfsprogs
            ];

            security.sudo.extraRules = [
              {
                users = [ "zfstest" ];
                commands = [
                  {
                    command = "ALL";
                    options = [ "NOPASSWD" ];
                  }
                ];
              }
            ];
          };
      })
      // {
        # Keep the ZTS scratch filesystem off tank. File-vdev writes through an
        # ext4 loop image on tank can recurse into the outer ZFS pool while its
        # txg_sync thread is waiting for that same I/O to complete.
        disks = [
          {
            type = "file";
            device = "{machine}-sda.img";
            size = "64G";
          }
          {
            type = "file";
            device = "{machine}-sdb.img";
            size = "48G";
          }
        ];
        shells = [ "zfs-run" ];
      };

    testScript = ''
      require 'fileutils'
      require 'shellwords'

      machine.start
      # Required test filesystems are explicitly loaded. Let the existing
      # service finish before starting the independent pool deadline.
      machine.wait_for_service('kernel-modules')
      machine.wait_for_service('nfsd')
      machine.wait_for_service('zfs-test-smb')
      machine.wait_until_succeeds("ss -H -lnt sport = :445 | grep -q '127.0.0.1:445'")
      # Under heavy parallel test load, osctld/pool activation can exceed the
      # default timeout and cause false-negative bootstrap failures.
      machine.wait_for_osctl_pool('tank', timeout: 20 * 60)

      _, zfs_root = machine.succeeds("cat /etc/zfs-full-suite-root")
      zfs_root = zfs_root.strip

      script_common = "#{zfs_root}/share/zfs/common.sh"
      zfs_tests_path = "#{zfs_root}/usr/share/initramfs-tools/scripts/zfs-tests.sh"
      zfs_test_runner = "#{zfs_root}/share/zfs/test-runner/bin/test-runner.py"
      zfs_test_report = "#{zfs_root}/share/zfs/test-runner/bin/zts-report.py"
      zfs_runfile_common = "#{zfs_root}/share/zfs/runfiles/common.run"
      zfs_runfile_linux = "#{zfs_root}/share/zfs/runfiles/linux.run"
      zfs_suite_dir = "#{zfs_root}/share/zfs/zfs-tests"
      zpool_script_dir = "/etc/zfs/zpool.d"

      machine.all_succeed(
        "test -f #{script_common}",
        "test -x #{zfs_tests_path}",
        "test -x #{zfs_test_runner}",
        "test -x #{zfs_test_report}",
        "test -f #{zfs_runfile_common}",
        "test -f #{zfs_runfile_linux}",
        "test -d #{zfs_suite_dir}",
        "test -f #{zfs_suite_dir}/include/default.cfg",
        "test -x #{zpool_script_dir}/iostat"
      )

      machine.all_succeed(
        # Raw local userspace stages are compiled with --prefix=/, so libzfs
        # resolves packaged compatibility basenames below //share/zfs. Expose
        # the adjusted package data at that path inside this test guest.
        "mkdir -p /share/zfs",
        "ln -s #{zfs_root}/share/zfs/compatibility.d /share/zfs/compatibility.d",
        "test -f /share/zfs/compatibility.d/2018",
        "id -u zfstest >/dev/null 2>&1 || useradd -m zfstest",
        "command -v losetup",
        "command -v dmsetup",
        "command -v bc",
        "command -v file",
        "command -v fio",
        "command -v jq",
        "command -v openssl",
        "command -v python3",
        "command -v chattr",
        "command -v getfattr",
        "command -v setfattr",
        "command -v lsscsi",
        "command -v mkfs.xfs",
        "command -v parted",
        "command -v net",
        "testparm -s /etc/samba/smb.conf",
        "mkdir -p /usr/bin",
        # libshare's Linux SMB backend uses the FHS path, not PATH lookup.
        "ln -sf $(command -v net) /usr/bin/net",
        "net usershare list",
        "command -v strings",
        "command -v getent",
        "ln -sf $(command -v bash) /bin/bash",
        "ln -sf $(command -v ksh) /bin/ksh",
        # ZFS helper mode executes hardcoded /bin/mount and /bin/umount.
        "ln -sf $(command -v mount) /bin/mount",
        "ln -sf $(command -v umount) /bin/umount",
        "mkdir -p /usr/local/bin",
        "if command -v xxh128sum >/dev/null 2>&1; then true; else ln -sf $(command -v xxhsum) /usr/local/bin/xxh128sum; fi",
        "test -x /bin/bash",
        "test -x /bin/ksh",
        "test -x /bin/mount",
        "test -x /bin/umount",
        "su - zfstest -c 'sudo -n id -un | grep -x root'",
        "mkdir -p /boot",
        "ln -s /etc/zfs-test/kernel-config /boot/config-$(uname -r)",
        "mkdir -p /var/tmp",
        "chmod 1777 /var/tmp",
        "mkdir -p /var/tmp/test_results",
        "chown zfstest /var/tmp/test_results",
        # Helper-based mount path (`/bin/mount`) expects a valid mtab target.
        "ln -snf /proc/self/mounts /etc/mtab",
        # zfs_share tests require the real server-backed export table.
        "test -r /etc/exports",
        "mkdir -p /mnt",
        "mkdir -p /tank/zfs-full-suite",
        "chown zfstest /tank/zfs-full-suite",
        "chmod 1777 /tank/zfs-full-suite",
        "chmod 0711 /run/osvm/shared-dir",
        "mkdir -p /run/osvm/shared-dir/zfs-full-suite",
        "chown zfstest /run/osvm/shared-dir/zfs-full-suite",
        "chmod 1777 /run/osvm/shared-dir/zfs-full-suite"
      )

      # zfs-tests starts its own ZED instance in several test groups.
      # Stop the system service first so zed_start does not fail with:
      # "ZED already running".
      machine.all_succeed(
        "sh -c 'if command -v sv >/dev/null 2>&1; then sv down zfs-zed >/dev/null 2>&1 || true; sv force-stop zfs-zed >/dev/null 2>&1 || true; fi'",
        "sh -c 'pkill -x zed >/dev/null 2>&1 || true; pkill -x lt-zed >/dev/null 2>&1 || true'",
        "sh -c 'for i in $(seq 1 30); do if ! pgrep -x zed >/dev/null 2>&1 && ! pgrep -x lt-zed >/dev/null 2>&1; then exit 0; fi; sleep 1; done; echo \"zed process still running\" >&2; exit 1'"
      )

      # Ask kernel hung-task detector to emit CPU backtraces so lockups
      # include actionable call stacks without relying on follow-up shell cmds.
      machine.all_succeed(
        "sh -c 'echo 1 > /proc/sys/kernel/hung_task_all_cpu_backtrace'",
        "sh -c 'echo 1 > /proc/sys/kernel/sysrq'",
        "sh -c 'echo 8 4 1 7 > /proc/sys/kernel/printk'"
      )

      profile = ENV.fetch('VPSADMINOS_ZFS_FULL_PROFILE', 'full')
      single_test = ENV['VPSADMINOS_ZFS_FULL_TEST']
      full_runfiles = Shellwords.escape(ENV.fetch('VPSADMINOS_ZFS_FULL_RUNFILES', 'common.run,linux.run'))
      full_tags = Shellwords.escape(ENV.fetch('VPSADMINOS_ZFS_FULL_TAGS', 'functional'))
      live_root = "/run/osvm/shared-dir/zfs-full-suite"
      live_log = "#{live_root}/zfs-tests-#{profile}.log"
      work_dir = "/var/tmp/zfs-full-suite"
      zpool_import_path = [
        work_dir,
        "/dev/disk/by-vdev",
        "/dev/mapper",
        "/dev/disk/by-partlabel",
        "/dev/disk/by-partuuid",
        "/dev/disk/by-label",
        "/dev/disk/by-uuid",
        "/dev/disk/by-id",
        "/dev/disk/by-path",
        "/dev"
      ].join(":")
      zts_env = "SYSTEMDIR=/var/tmp/zfs-constrained-path.XXXXXX LOSETUP=$(command -v losetup) DMSETUP=$(command -v dmsetup) SCRIPT_COMMON=#{script_common} ZTS_REPORT=#{zfs_test_report} ZPOOL_IMPORT_PATH=#{zpool_import_path}"
      state_dir = File.dirname(machine.send(:console_log_path))
      host_live_root = File.join(state_dir, "shared-dir", "zfs-full-suite")
      host_live_log = File.join(host_live_root, "zfs-tests-#{profile}.log")
      captured_live_log = File.join(state_dir, "zfs-tests-#{profile}.captured.log")
      captured_hung_stacks = File.join(state_dir, "hung-task-stacks.log")
      captured_oom_events = File.join(state_dir, "oom-events.log")
      captured_dmesg_log = File.join(state_dir, "zfs-tests-#{profile}.dmesg.log")
      captured_results_dir = File.join(state_dir, "zfs-test-results")
      disk_paths = machine.send(:config).disks.filter_map do |disk|
        next unless disk.type == 'file'

        machine.send(:disk_path, disk.device)
      end.sort

      disk_progress = lambda do
        disk_paths.map do |path|
          stat = File.stat(path)
          [path, stat.blocks, stat.mtime.to_i, stat.mtime.nsec]
        end
      end

      machine.all_succeed(
        # Keep the ZFS test workdir on a separate ext4 disk. Besides avoiding
        # sparse-zero accounting differences for file-vdev TRIM tests, this
        # prevents file-vdev I/O from recursing through tank.
        "sh -c 'if mountpoint -q #{work_dir}; then umount #{work_dir}; fi'",
        "rm -rf #{work_dir}",
        "mkfs.ext4 -F -q /dev/sdb",
        "mkdir -p #{work_dir}",
        "mount /dev/sdb #{work_dir}",
        "test \"$(stat -f -c %T #{work_dir})\" = ext2/ext3",
        "chown zfstest #{work_dir}",
        "chmod 1777 #{work_dir}",
        "mkdir -p #{live_root}/work",
        "rm -f #{live_log}",
        "rm -rf #{live_root}/test_results",
        "rm -f #{live_root}/dmesg-after.log"
      )

      if single_test && !single_test.empty?
        if single_test.include?('/')
          candidate =
            if single_test.start_with?('/')
              single_test
            elsif single_test.start_with?('tests/')
              "#{zfs_suite_dir}/#{single_test}"
            else
              "#{zfs_suite_dir}/tests/functional/#{single_test}"
            end
          candidates = [candidate, "#{candidate}.ksh"]
          resolve_cmd = "for path in #{candidates.map { |path| Shellwords.escape(path) }.join(' ')}; do if [ -x \"$path\" ]; then printf '%s\\n' \"$path\"; exit 0; fi; done; exit 1"
          _, single_test = machine.succeeds(resolve_cmd)
          single_test = single_test.strip
        end

        # Match common.run's blank user override for cli_user groups when the
        # single-test runfile is generated by zfs-tests.sh.
        single_test_user = single_test.include?('/cli_user/') ? 'zfstest' : 'root'
        cmd = "set -o pipefail; cd #{work_dir} && #{zts_env} #{zfs_tests_path} -v -x -d #{work_dir} -t #{Shellwords.escape(single_test)} -u #{single_test_user} 2>&1 | tee #{live_log}"
        timeout = 2 * 60 * 60
      else
        case profile
        when 'full'
          cmd = "set -o pipefail; cd #{work_dir} && #{zts_env} #{zfs_tests_path} -v -x -d #{work_dir} -r #{full_runfiles} -T #{full_tags} 2>&1 | tee #{live_log}"
          timeout = 24 * 60 * 60
        when 'sanity'
          cmd = "set -o pipefail; cd #{work_dir} && #{zts_env} #{zfs_tests_path} -v -x -d #{work_dir} -r sanity.run -T functional 2>&1 | tee #{live_log}"
          timeout = 3 * 60 * 60
        when 'smoke'
          cmd = "set -o pipefail; cd #{work_dir} && #{zts_env} #{zfs_tests_path} -v -x -f -d #{work_dir} -t tests/functional/cli_root/zfs_create/zfs_create_001_pos.ksh 2>&1 | tee #{live_log}"
          timeout = 60 * 60
        else
          raise "Unsupported VPSADMINOS_ZFS_FULL_PROFILE=#{profile.inspect}, expected full|sanity|smoke"
        end
      end

      require '${pkgs.writeText "zfs_disk_progress_hang_detector.rb" (builtins.readFile ./disk_progress_hang_detector.rb)}'

      hung_line_regex = ZfsDiskProgressHangDetector::HUNG_LINE
      oom_regex = /(invoked oom-killer|Out of memory: Killed process)/
      hung_detected = false
      oom_detected = false
      hung_wait_error = nil
      oom_wait_error = nil
      run_error = nil
      result_error = nil

      run_thread = Thread.new do
        begin
          machine.shells['zfs-run'].succeeds("su - zfstest -c #{cmd.inspect}", timeout: timeout)
        rescue StandardError => e
          run_error = e
        end
      end

      hung_thread = Thread.new do
        begin
          detector = ZfsDiskProgressHangDetector.new(&disk_progress)
          console_log = machine.send(:console_log_path)
          console_offset = 0
          console_remainder = String.new
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

          loop do
            if File.file?(console_log)
              File.open(console_log, 'rb') do |f|
                f.seek(console_offset)
                chunk = f.read
                console_offset = f.pos
                console_remainder << chunk if chunk
              end

              lines = console_remainder.split("\n", -1)
              console_remainder = lines.pop || String.new

              if lines.any? { |line| detector.observe(line) }
                hung_detected = true
                break
              end
            end

            break unless run_thread.alive?
            break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep(0.25)
          end
        rescue StandardError => e
          hung_wait_error = e
        end
      end

      oom_thread = Thread.new do
        begin
          machine.wait_for_console_text(oom_regex, timeout: timeout)
          oom_detected = true
        rescue OsVm::TimeoutError
          # OOM signature did not appear before run finished.
        rescue StandardError => e
          oom_wait_error = e
        end
      end

      while run_thread.alive? && !hung_detected && !oom_detected
        sleep(1)
      end

      if hung_detected || oom_detected
        console_log = machine.send(:console_log_path)

        if hung_detected
          hung_pairs = []

          if File.file?(console_log)
            hung_pairs = File.binread(console_log)
                             .scan(hung_line_regex)
                             .uniq
          end

          if hung_pairs.any?
            File.open(captured_hung_stacks, "w") do |f|
              hung_pairs.each do |task, pid|
                f.puts("#{task}:#{pid}")
              end
            end
          end

          # Best-effort sysrq trigger from guest shell without blocking test flow.
          begin
            machine.execute(
              "sh -c '(echo w > /proc/sysrq-trigger; sleep 1; echo t > /proc/sysrq-trigger) >/dev/null 2>&1 &'",
              timeout: 5
            )
          rescue StandardError
            # pass
          end
        end

        if oom_detected && File.file?(console_log)
          oom_lines = File.binread(console_log)
                          .lines
                          .grep(/invoked oom-killer|Out of memory: Killed process/)
          if oom_lines.any?
            File.open(captured_oom_events, "w") do |f|
              oom_lines.last(200).each { |line| f.write(line) }
            end
          end
        end

        # Keep VM running briefly so kernel logs can flush to serial console.
        sleep(10)

        begin
          machine.kill(signal: 'KILL')
        rescue StandardError
          # pass
        end
      end

      run_thread.join
      hung_thread.kill if hung_thread.alive?
      hung_thread.join
      oom_thread.kill if oom_thread.alive?
      oom_thread.join

      unless hung_detected || oom_detected
        begin
          machine.execute(
            "sh -c 'if [ -d /var/tmp/test_results ]; then rm -rf #{live_root}/test_results; mkdir -p #{live_root}/test_results; cp -a /var/tmp/test_results/. #{live_root}/test_results/; fi'",
            timeout: 120
          )
        rescue StandardError
          # pass
        end

        begin
          machine.execute(
            "sh -c 'dmesg -T > #{live_root}/dmesg-after.log'",
            timeout: 30
          )
        rescue StandardError
          # pass
        end

        begin
          machine.execute(
            "sh -c 'cp -a #{work_dir}/zts-results.* #{live_root}/work/ 2>/dev/null || true'",
            timeout: 30
          )
        rescue StandardError
          # pass
        end

        if run_error
          begin
            machine.execute(
              "sh -c 'if [ -d /var/tmp/test_results ]; then find /var/tmp/test_results -maxdepth 4 -type f -print; fi'",
              timeout: 30
            )
          rescue StandardError
            # pass
          end

          begin
            machine.execute(
              "sh -c 'if [ -d /var/tmp/test_results ]; then for f in $(find /var/tmp/test_results -maxdepth 4 -type f | sort); do echo \"===== $f =====\"; sed -n \"1,200p\" \"$f\"; done; fi'",
              timeout: 180
            )
          rescue StandardError
            # pass
          end

          begin
            machine.execute(
              "sh -c 'echo \"===== exportfs -v =====\"; exportfs -v 2>&1 || true; echo \"===== /etc/exports =====\"; sed -n \"1,200p\" /etc/exports 2>&1 || true; echo \"===== /etc/exports.d/zfs.exports =====\"; sed -n \"1,200p\" /etc/exports.d/zfs.exports 2>&1 || true'",
              timeout: 30
            )
          rescue StandardError
            # pass
          end
        end
      end

      if File.file?(host_live_log)
        File.binwrite(captured_live_log, File.binread(host_live_log))
      end

      if run_error.nil?
        if !File.file?(host_live_log)
          result_error = RuntimeError.new("ZFS test-suite run produced no live result log: #{host_live_log}")
        else
          zts_output = File.binread(host_live_log)
          result_lines = zts_output.lines.grep(/^\[[^\]]+\] Test(?: \([^)]+\))?: .* \[[A-Z]+\]$/)
          failed_results = result_lines.reject do |line|
            line.rstrip.end_with?('[PASS]', '[SKIP]')
          end

          if result_lines.empty?
            result_error = RuntimeError.new("ZFS test-suite run executed zero tests; captured log: #{captured_live_log}")
          elsif failed_results.any?
            # Upstream expected failures still require a causal disposition;
            # neither a full run nor a selected tag may silently accept them.
            result_error = RuntimeError.new("ZFS test-suite raw failures: #{failed_results.join.strip}; captured log: #{captured_live_log}")
          elsif single_test
            selected_name = File.basename(single_test).delete_suffix('.ksh')
            selected_results = result_lines.select do |line|
              path = line.match(/Test(?: \([^)]+\))?: (\S+)/)[1]
              File.basename(path).delete_suffix('.ksh') == selected_name
            end
            if selected_results.empty?
              result_error = RuntimeError.new("Focused ZFS test #{single_test.inspect} produced no result; captured log: #{captured_live_log}")
            elsif selected_results.any? { |line| !line.rstrip.end_with?('[PASS]') }
              # Upstream expected-FAIL/SKIP classifications are not acceptance
              # when explicitly validating one formerly skipped body.
              result_error = RuntimeError.new("Focused ZFS test did not PASS: #{selected_results.join.strip}; captured log: #{captured_live_log}")
            end
          end
        end
      end

      host_results_dir = File.join(host_live_root, "test_results")
      if Dir.exist?(host_results_dir)
        FileUtils.rm_rf(captured_results_dir)
        FileUtils.mkdir_p(captured_results_dir)
        Dir.children(host_results_dir).each do |entry|
          src = File.join(host_results_dir, entry)
          dst = File.join(captured_results_dir, entry)

          # zfs-tests keeps "current" as a symlink that may become dangling.
          # Skip symlinks so result collection never fails before reporting.
          next if File.symlink?(src)

          if Dir.exist?(src)
            FileUtils.cp_r(src, dst)
          elsif File.file?(src)
            FileUtils.cp(src, dst)
          end
        end
      end

      host_dmesg_log = File.join(host_live_root, "dmesg-after.log")
      if File.file?(host_dmesg_log)
        File.binwrite(captured_dmesg_log, File.binread(host_dmesg_log))
      end

      Dir.glob(File.join(host_live_root, "work", "zts-results.*")).each do |src|
        dst = File.join(state_dir, File.basename(src))
        File.binwrite(dst, File.binread(src))
      end

      if hung_detected
        console_log = machine.send(:console_log_path)
        raise "Detected persistent kernel hung task without disk-image progress during ZFS test-suite run (#{hung_line_regex.inspect}). Live log in guest: #{live_log}; captured live log on host: #{captured_live_log}; captured hung stacks on host: #{captured_hung_stacks}; console log on host: #{console_log}"
      end

      if oom_detected
        console_log = machine.send(:console_log_path)
        raise "Detected guest OOM during ZFS test-suite run (#{oom_regex.inspect}). Live log in guest: #{live_log}; captured live log on host: #{captured_live_log}; captured OOM events on host: #{captured_oom_events}; console log on host: #{console_log}"
      end

      raise hung_wait_error if hung_wait_error
      raise oom_wait_error if oom_wait_error
      raise result_error if result_error
      raise run_error if run_error
    '';
  }
)

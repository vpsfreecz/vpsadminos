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

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        { config, pkgs, lib, ... }:
        let
          kernelPackages = import ../../../os/packages/linux/packages.nix {
            inherit
              config
              pkgs
              lib
              ;
          };

          # Keep OpenZFS test-suite files in the userspace package for this test only.
          zfsUserWithTests = (kernelPackages.genZfsUserPackage config.boot.kernelVersion).overrideAttrs (
            old: {
              postInstall =
                (lib.replaceStrings
                  [ "rm -rf $out/share/zfs/zfs-tests" ]
                  [ "echo 'keeping zfs-tests for zfs-full-suite'" ]
                  (old.postInstall or ""))
                + ''
                  # vpsAdminOS exposes most commands under /run/current-system/sw.
                  substituteInPlace $out/usr/share/initramfs-tools/scripts/zfs-tests.sh \
                    --replace 'SYSTEM_DIRS="/usr/local/bin /usr/local/sbin"' \
                              'SYSTEM_DIRS="/run/wrappers/bin /usr/local/bin /usr/local/sbin /run/current-system/sw/bin /run/current-system/sw/sbin"'

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
            }
          );
        in
        {
          # Keep bisect/repro runs fast: avoid rebuilding kernel with ZFS built-in.
          boot.zfsBuiltin = lib.mkForce false;
          boot.zfsUserPackage = lib.mkForce zfsUserWithTests;
          # Prevent fd0 probing noise/stalls during long ZFS test runs.
          boot.blacklistedKernelModules = [ "floppy" ];
          boot.kernelParams = [ "floppy=off" ];

          # zfs-tests.sh requires ksh and passwordless sudo for the run user.
          environment.systemPackages = [
            pkgs.attr
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
    };

    testScript = ''
      require 'fileutils'

      machine.start
      machine.wait_for_osctl_pool('tank')

      _, zfs_root = machine.succeeds(
        "sh -c 'zfs_bin=$(readlink -f $(command -v zfs)); dirname $(dirname \"$zfs_bin\")'"
      )
      zfs_root = zfs_root.strip

      script_common = "#{zfs_root}/share/zfs/common.sh"
      zfs_tests_path = "#{zfs_root}/usr/share/initramfs-tools/scripts/zfs-tests.sh"
      zfs_test_runner = "#{zfs_root}/share/zfs/test-runner/bin/test-runner.py"
      zfs_runfile_common = "#{zfs_root}/share/zfs/runfiles/common.run"
      zfs_runfile_linux = "#{zfs_root}/share/zfs/runfiles/linux.run"
      zfs_suite_dir = "#{zfs_root}/share/zfs/zfs-tests"

      machine.all_succeed(
        "test -f #{script_common}",
        "test -x #{zfs_tests_path}",
        "test -x #{zfs_test_runner}",
        "test -f #{zfs_runfile_common}",
        "test -f #{zfs_runfile_linux}",
        "test -d #{zfs_suite_dir}",
        "test -f #{zfs_suite_dir}/include/default.cfg"
      )

      machine.all_succeed(
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
        "command -v parted",
        "command -v net",
        "command -v strings",
        "command -v getent",
        "ln -sf $(command -v ksh) /bin/ksh",
        "mkdir -p /usr/local/bin",
        "if command -v xxh128sum >/dev/null 2>&1; then true; else ln -sf $(command -v xxhsum) /usr/local/bin/xxh128sum; fi",
        "test -x /bin/ksh",
        "su - zfstest -c 'sudo -n id -un | grep -x root'",
        "mkdir -p /var/tmp",
        "chmod 1777 /var/tmp",
        "mkdir -p /var/tmp/test_results",
        "chown zfstest /var/tmp/test_results",
        "mkdir -p /mnt",
        "mkdir -p /var/tmp/zfs-full-suite",
        "chmod 1777 /var/tmp/zfs-full-suite",
        "mkdir -p /run/osvm/shared-dir/zfs-full-suite",
        "chown zfstest /run/osvm/shared-dir/zfs-full-suite",
        "chmod 1777 /run/osvm/shared-dir/zfs-full-suite"
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
      live_root = "/run/osvm/shared-dir/zfs-full-suite"
      live_log = "#{live_root}/zfs-tests-#{profile}.log"
      work_dir = "#{live_root}/work"
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
      state_dir = File.dirname(machine.send(:console_log_path))
      host_live_root = File.join(state_dir, "shared-dir", "zfs-full-suite")
      host_live_log = File.join(host_live_root, "zfs-tests-#{profile}.log")
      captured_live_log = File.join(state_dir, "zfs-tests-#{profile}.captured.log")
      captured_hung_stacks = File.join(state_dir, "hung-task-stacks.log")
      captured_dmesg_log = File.join(state_dir, "zfs-tests-#{profile}.dmesg.log")
      captured_results_dir = File.join(state_dir, "zfs-test-results")

      machine.all_succeed(
        "mkdir -p #{work_dir}",
        "chown zfstest #{work_dir}",
        "chmod 1777 #{work_dir}",
        "rm -f #{live_log}",
        "rm -rf #{live_root}/test_results",
        "rm -f #{live_root}/dmesg-after.log"
      )

      if single_test && !single_test.empty?
        cmd = "set -o pipefail; cd #{work_dir} && LOSETUP=$(command -v losetup) DMSETUP=$(command -v dmsetup) SCRIPT_COMMON=#{script_common} ZPOOL_IMPORT_PATH=#{zpool_import_path} #{zfs_tests_path} -v -x -d #{work_dir} -t #{single_test} 2>&1 | tee #{live_log}"
        timeout = 2 * 60 * 60
      else
        case profile
        when 'full'
          cmd = "set -o pipefail; cd #{work_dir} && LOSETUP=$(command -v losetup) DMSETUP=$(command -v dmsetup) SCRIPT_COMMON=#{script_common} ZPOOL_IMPORT_PATH=#{zpool_import_path} #{zfs_tests_path} -v -x -d #{work_dir} -r common.run,linux.run -T functional 2>&1 | tee #{live_log}"
          timeout = 12 * 60 * 60
        when 'sanity'
          cmd = "set -o pipefail; cd #{work_dir} && LOSETUP=$(command -v losetup) DMSETUP=$(command -v dmsetup) SCRIPT_COMMON=#{script_common} ZPOOL_IMPORT_PATH=#{zpool_import_path} #{zfs_tests_path} -v -x -d #{work_dir} -r sanity.run -T functional 2>&1 | tee #{live_log}"
          timeout = 3 * 60 * 60
        when 'smoke'
          cmd = "set -o pipefail; cd #{work_dir} && LOSETUP=$(command -v losetup) DMSETUP=$(command -v dmsetup) SCRIPT_COMMON=#{script_common} ZPOOL_IMPORT_PATH=#{zpool_import_path} #{zfs_tests_path} -v -x -f -d #{work_dir} -t tests/functional/cli_root/zfs_create/zfs_create_001_pos.ksh 2>&1 | tee #{live_log}"
          timeout = 60 * 60
        else
          raise "Unsupported VPSADMINOS_ZFS_FULL_PROFILE=#{profile.inspect}, expected full|sanity|smoke"
        end
      end

      hung_regex = /INFO: task (txg_sync|zpool):[0-9]+ blocked for more than/
      hung_detected = false
      hung_wait_error = nil
      run_error = nil

      run_thread = Thread.new do
        begin
          machine.succeeds("su - zfstest -c #{cmd.inspect}", timeout: timeout)
        rescue StandardError => e
          run_error = e
        end
      end

      hung_thread = Thread.new do
        begin
          machine.wait_for_console_text(hung_regex, timeout: timeout)
          hung_detected = true
        rescue OsVm::TimeoutError
          # Hung-task warning did not appear before run finished.
        rescue StandardError => e
          hung_wait_error = e
        end
      end

      while run_thread.alive? && !hung_detected
        sleep(1)
      end

      if hung_detected
        console_log = machine.send(:console_log_path)
        hung_pairs = []

        if File.file?(console_log)
          hung_pairs = File.binread(console_log)
                           .scan(/INFO: task (txg_sync|zpool):([0-9]+) blocked for more than/)
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

      unless hung_detected
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
        end
      end

      if File.file?(host_live_log)
        File.binwrite(captured_live_log, File.binread(host_live_log))
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
        raise "Detected kernel hung task during ZFS test-suite run (#{hung_regex.inspect}). Live log in guest: #{live_log}; captured live log on host: #{captured_live_log}; captured hung stacks on host: #{captured_hung_stacks}; console log on host: #{console_log}"
      end

      raise hung_wait_error if hung_wait_error
      raise run_error if run_error
    '';
  }
)

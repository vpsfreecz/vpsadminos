import ../../make-test.nix (
  { pkgs }:
  {
    name = "kernel-sched-proxy-exec";

    description = ''
      Validate scheduler proxy execution with kernel mutex contention
    '';

    tags = [ "proxy-exec" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config =
        { lib, pkgs, ... }:
        {
          imports = [
            ../../../os/configs/proxy-exec-qemu.nix
          ];

          environment.systemPackages = with pkgs; [
            coreutils
            gzip
            gnugrep
            kmod
            procps
          ];

          networking.firewall.enable = lib.mkForce false;
          networking.lxcbr.enable = lib.mkForce false;

          boot.qemu.memory = lib.mkOverride 0 3072;
          boot.qemu.cpus = lib.mkOverride 0 4;
          boot.qemu.cpu.cores = lib.mkOverride 0 4;
          boot.qemu.cpu.threads = lib.mkOverride 0 1;
          boot.qemu.cpu.sockets = lib.mkOverride 0 1;
        };
    };

    testScript = ''
      require 'shellwords'

      def self.expect_kernel_config(name, expected)
        expected_line = "#{name}=#{expected}"
        status, output = machine.execute(
          "timeout 30 sh -c " \
          "#{Shellwords.escape("gzip -dc /proc/config.gz | grep -Fx #{Shellwords.escape(expected_line)}")}",
          timeout: 45
        )
        expect(status).to eq(0),
          "#{expected_line} is missing from /proc/config.gz: #{output}"
      end

      def self.expect_clean_kernel_log(log)
        bad = /
          BUG:|
          WARNING:|
          Oops:|
          kernel\s+BUG|
          general\s+protection\s+fault|
          psi:\s+inconsistent\s+task\s+state|
          INFO:\s+task\s+.+\s+blocked\s+for\s+more\s+than|
          rcu:.*stall|
          RCU\s+stall|
          soft\s+lockup|
          hard\s+LOCKUP|
          End\s+of\s+test:\s+FAILURE|
          End\s+of\s+test:\s+LOCK_HOTPLUG|
          !!!
        /x

        expect(log).not_to match(bad)
      end

      def self.run_locktorture(label, proxy_arg, expected_boot_message)
        kernel_params = [
          proxy_arg,
          "oops=panic",
          "softlockup_panic=1",
          "hardlockup_panic=1",
          "hung_task_panic=1",
        ]

        machine.stop if machine.running?
        machine.start(kernel_params:)
        machine.wait_until_online

        expect_kernel_config("CONFIG_SCHED_PROXY_EXEC", "y")
        expect_kernel_config("CONFIG_PSI", "y")
        expect_kernel_config("CONFIG_LOCK_TORTURE_TEST", "m")

        cmdline = machine.succeeds("cat /proc/cmdline")[1]
        expect(cmdline).to include(proxy_arg)

        boot_log = machine.succeeds("dmesg")[1]
        expect(boot_log).to include(expected_boot_message)

        machine.succeeds("dmesg -C || true")

        status, output = machine.execute(<<~SH, timeout: 180)
          set -eu

          modprobe locktorture \\
            torture_type=mutex_lock \\
            nwriters_stress=16 \\
            nreaders_stress=0 \\
            long_hold=20 \\
            nested_locks=2 \\
            stutter=0 \\
            shuffle_interval=1 \\
            stat_interval=5 \\
            rt_boost=0 \\
            verbose=1

          sleep 60
          rmmod locktorture
          dmesg
        SH

        expect(status).to eq(0), output
        expect(output).to include("Start of test"), output
        expect(output).to include("End of test: SUCCESS"), output
        expect_clean_kernel_log(output)

        machine.stop
      end

      run_locktorture(
        "enabled",
        "sched_proxy_exec=1",
        "sched_proxy_exec enabled via boot arg"
      )

      run_locktorture(
        "disabled-control",
        "sched_proxy_exec=0",
        "sched_proxy_exec disabled via boot arg"
      )
    '';
  }
)

import ../../make-test.nix (
  { pkgs }:
  let
    selectors = import ../../../os/packages/linux/cred-guard-test-selectors.nix;

    authGuardCases = import ./cred-guard/cases.nix;
    authGuardLsms = [
      "landlock"
      "yama"
      "selinux"
      "bpf"
    ];
    authGuardCasesJson =
      assert builtins.length authGuardCases == 18;
      assert
        builtins.length (pkgs.lib.unique (builtins.map (testCase: testCase.command) authGuardCases)) == 18;
      assert pkgs.lib.all (
        testCase:
        builtins.elem testCase.trigger [
          "debugfs"
          "seccomp_filter"
        ]
      ) authGuardCases;
      builtins.toJSON authGuardCases;

    seccompFilterTrigger = pkgs.stdenv.mkDerivation {
      pname = "auth-guard-seccomp-filter-trigger";
      version = "1";

      dontUnpack = true;

      src = ./cred-guard/seccomp-filter-trigger.c;

      buildPhase = ''
        runHook preBuild
        $CC $src -Wall -Wextra -Werror -O2 -pthread \
          -o auth-guard-seccomp-filter-trigger
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        install -m 0755 auth-guard-seccomp-filter-trigger \
          $out/bin/auth-guard-seccomp-filter-trigger
        runHook postInstall
      '';
    };

    testPrelude = ''
      require 'json'
      require 'shellwords'

      def self.auth_guard_cases
        JSON.parse(${builtins.toJSON authGuardCasesJson})
      end

      def self.auth_guard_lsms
        ${builtins.toJSON authGuardLsms}
      end

      def self.auth_guard_message(test_case)
        domain = test_case.fetch("domain")
        command = test_case.fetch("command")
        reason = test_case.fetch("reason")

        "auth_guard: #{domain}: auth_guard_test:#{command}: #{reason}"
      end

      def self.auth_guard_messages(log)
        log.lines.filter_map do |line|
          marker = line.index("auth_guard:")
          line[marker..].strip.split(" object=", 2).first if marker
        end
      end

      def self.auth_guard_helper_command(command)
        helper =
          ${builtins.toJSON "${seccompFilterTrigger}/bin/auth-guard-seccomp-filter-trigger"}
        "#{Shellwords.escape(helper)} #{Shellwords.escape(command)}"
      end

      def self.auth_guard_trigger(test_case)
        command = test_case.fetch("command")

        case test_case.fetch("trigger")
        when "debugfs"
          "printf '%s\n' #{Shellwords.escape(command)} " \
            "> /sys/kernel/debug/auth_guard/corrupt_current"
        when "seccomp_filter"
          auth_guard_helper_command(command)
        else
          raise "unsupported auth-guard trigger: #{test_case.fetch("trigger")}"
        end
      end

      def self.expect_kernel_config(name, expected)
        expected_line = "#{name}=#{expected}"
        status, output = machine.execute(
          "timeout 30 sh -c " \
          "#{Shellwords.escape(
            "gzip -dc /proc/config.gz | grep -Fx #{Shellwords.escape(expected_line)}"
          )}",
          timeout: 45
        )
        expect(status).to eq(0),
          "#{expected_line} is missing from /proc/config.gz: #{output}"
      end

      def self.prepare_guard_machine(mode, verify_config: true)
        machine.start(kernel_params: ["auth_guard=#{mode}"])
        machine.wait_until_online

        _, cmdline = machine.succeeds("cat /proc/cmdline")
        expect(cmdline.split).to include("auth_guard=#{mode}")
        expect(cmdline.split).to include("lsm=#{auth_guard_lsms.join(",")}")

        _, lsm_list = machine.succeeds("cat /sys/kernel/security/lsm")
        expect(lsm_list.strip.split(",")).to eq(["capability"] + auth_guard_lsms)

        if verify_config
          _, release = machine.succeeds("uname -r")
          expect(release.strip).to start_with("6.18")

          %w[
            CONFIG_CRED_GUARD
            CONFIG_AUTH_GUARD
            CONFIG_SELINUX_CRED_GUARD
            CONFIG_AUTH_GUARD_TEST
            CONFIG_SECURITY_SELINUX
            CONFIG_CGROUPS
            CONFIG_SECCOMP_FILTER
            CONFIG_SYSLOG_NS
            CONFIG_TRACING_NS
          ].each { |name| expect_kernel_config(name, "y") }
        end

        machine.succeeds(
          "mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug"
        )
        machine.succeeds("test -w /sys/kernel/debug/auth_guard/corrupt_current")
      end
    '';
  in
  {
    name = "kernel-cred-guard";

    description = ''
      Verify the vpsAdminOS 6.18 kernel enables cred/auth guards and
      corruption reporting
    '';

    tags = [ "cred-guard" ];

    machine = import ../../machines/vpsadminos/with-empty.nix {
      inherit pkgs;
      config =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          kernelPackages = import ../../../os/packages/linux/packages.nix {
            inherit
              config
              lib
              pkgs
              ;
          };

          linuxSnapshot = builtins.getEnv "VPSADMINOS_LINUX_SNAPSHOT";
          kernelVersionEnv = builtins.getEnv "VPSADMINOS_CRED_GUARD_KERNEL_VERSION";

          kernelVersion = if kernelVersionEnv == "" then kernelPackages.defaultVersion else kernelVersionEnv;
          kernelDef = kernelPackages.kernels.${kernelVersion};

          linuxSource = /. + linuxSnapshot;
          linuxMakefile = lib.splitString "\n" (builtins.readFile (linuxSource + "/Makefile"));
          linuxMakeVariable =
            name:
            let
              line = lib.findFirst (line: lib.hasPrefix "${name} =" line) null linuxMakefile;
            in
            if line == null then
              throw "Linux snapshot Makefile does not define ${name}"
            else
              lib.removePrefix " " (lib.removePrefix "${name} =" line);
          snapshotKernelVersion = "${linuxMakeVariable "VERSION"}.${linuxMakeVariable "PATCHLEVEL"}.${linuxMakeVariable "SUBLEVEL"}${linuxMakeVariable "EXTRAVERSION"}";

          kernelFeatures = if builtins.hasAttr "features" kernelDef then kernelDef.features else { };

          localKernel =
            if linuxSnapshot == "" then
              null
            else
              pkgs.callPackage ../../../os/packages/linux/generic.nix (rec {
                version = snapshotKernelVersion;
                modDirVersion = version;
                extraMeta.branch = lib.concatStringsSep "." (lib.take 2 (lib.splitString "." version));
                src = linuxSource;
                kernelPatches = [ pkgs.kernelPatches.bridge_stp_helper ];
                features = kernelFeatures;
                structuredExtraConfig = kernelDef.structuredExtraConfig or { };
                zfsBuiltinPkg = null;
              });

          pinnedKernel = pkgs.callPackage ../../../os/packages/linux {
            inherit kernelVersion;
            url = "https://github.com/vpsfreecz/linux/archive/${kernelDef.rev}.tar.gz";
            sha256 = kernelDef.sha256;
            features = kernelFeatures;
            structuredExtraConfig = kernelDef.structuredExtraConfig or { };
          };
        in
        {
          environment.systemPackages = with pkgs; [
            coreutils
            gzip
            gnugrep
            util-linux
            seccompFilterTrigger
          ];

          boot.kernelVersion = lib.mkForce kernelVersion;
          boot.kernelPackage = lib.mkForce (if localKernel != null then localKernel else pinnedKernel);
          boot.enableUnifiedCgroupHierarchy = lib.mkForce false;
          boot.zfsBuiltin = lib.mkForce false;

          security.lsm = lib.mkForce authGuardLsms;

          boot.qemu.memory = lib.mkOverride 0 2048;
          boot.qemu.cpus = lib.mkOverride 0 1;
          boot.qemu.cpu.cores = lib.mkOverride 0 1;
          boot.qemu.cpu.threads = lib.mkOverride 0 1;
          boot.qemu.cpu.sockets = lib.mkOverride 0 1;
        };
    };

    testScripts =
      pkgs.lib.optionalAttrs selectors.log.requested {
        log = {
          tags = [ "log" ];
          script = testPrelude + ''
            prepare_guard_machine("log")
            _, boot_log = machine.succeeds("dmesg")
            expect(boot_log).not_to include("auth_guard:")
            machine.succeeds("dmesg -C")

            machine.succeeds("sh -c 'exec true'")
            machine.succeeds(<<~'SH', timeout: 60)
              set -eu
              host_ns=`readlink /proc/self/ns/mnt`
              unshare --mount sh -c 'mount --make-rprivate /; exec sleep 30' &
              pid=$!
              cleanup() {
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
              }
              trap cleanup EXIT

              i=0
              while [ "$i" -lt 50 ]; do
                target_ns=`readlink /proc/"$pid"/ns/mnt 2>/dev/null || true`
                [ -n "$target_ns" ] && [ "$target_ns" != "$host_ns" ] && break
                sleep 0.1
                i=$((i + 1))
              done
              [ -n "$target_ns" ]
              [ "$target_ns" != "$host_ns" ]
              nsenter --mount=/proc/"$pid"/ns/mnt true
            SH
            machine.succeeds(<<~'SH', timeout: 60)
              set -eu
              cgroup=/sys/fs/cgroup/systemd/auth-guard-smoke
              rmdir "$cgroup" 2>/dev/null || true
              mkdir "$cgroup"
              sleep 30 &
              pid=$!
              cleanup() {
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                rmdir "$cgroup" 2>/dev/null || true
              }
              trap cleanup EXIT

              echo "$pid" > "$cgroup/tasks"
              kill "$pid"
              wait "$pid" 2>/dev/null || true
              rmdir "$cgroup"
              trap - EXIT
            SH
            %w[seccomp_smoke files_unshare].each do |command|
              machine.succeeds(auth_guard_helper_command(command))
            end

            _, transition_log = machine.succeeds("dmesg")
            expect(transition_log).not_to include("auth_guard:")

            auth_guard_cases.each do |test_case|
              machine.succeeds(auth_guard_trigger(test_case))
              message = auth_guard_message(test_case)
              machine.succeeds(
                "dmesg | grep -F #{Shellwords.escape(message)}",
                timeout: 30
              )
            end

            _, corruption_log = machine.succeeds("dmesg")
            expected_messages = auth_guard_cases.map do |test_case|
              auth_guard_message(test_case)
            end
            expect(auth_guard_messages(corruption_log).tally).to eq(expected_messages.tally)
          '';
        };
      }
      // pkgs.lib.optionalAttrs selectors.panic.requested {
        panic = {
          tags = [ "panic" ];
          script = testPrelude + ''
            auth_guard_cases.each_with_index do |test_case, index|
              begin
                prepare_guard_machine("panic", verify_config: index.zero?)
                trigger = auth_guard_trigger(test_case)
                delayed_trigger = "sleep 5; #{trigger}"
                message = auth_guard_message(test_case)
                panic_pattern = /Kernel panic - not syncing: #{Regexp.escape(message)}/

                machine.allow_kernel_failure(panic_pattern) do
                  machine.succeeds(
                    "nohup sh -c #{Shellwords.escape(delayed_trigger)} " \
                    "</dev/null >/dev/null 2>&1 &"
                  )
                  machine.wait_for_console_text(panic_pattern, timeout: 30)
                end
              ensure
                machine.kill(signal: 'KILL') if machine.running?
              end
            end
          '';
        };
      };
  }
)

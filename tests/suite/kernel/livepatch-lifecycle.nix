import ../../make-template.nix (
  { kernelVersion }:
  let
    line = import (./livepatch-lifecycle + "/${kernelVersion}.nix");
  in
  rec {
    instance = kernelVersion;

    test =
      { pkgs }:
      let
        lib = pkgs.lib;
        patches = import ../../../os/livepatches/available-patches.nix {
          inherit lib;
          version = kernelVersion;
        };
        candidateVersion = patches.patchVersion;
        candidateName = "livepatch_${toString candidateVersion}";
        predecessors = line.predecessors or { };

        kvmSmoke = pkgs.stdenv.mkDerivation {
          pname = "livepatch-lifecycle-kvm-smoke";
          version = "1";
          src = ./livepatch-lifecycle;

          dontConfigure = true;

          buildPhase = ''
            "$CC" -std=gnu11 -O2 -Wall -Wextra -Werror \
              -o kvm_smoke kvm_smoke.c
          '';

          installPhase = ''
            install -Dm755 kvm_smoke "$out/bin/kvm_smoke"
          '';
        };

        predecessorEtc = lib.mapAttrs' (
          vendor: predecessor:
          lib.nameValuePair "livepatch-lifecycle/predecessor-${vendor}.ko" {
            source = predecessor.module;
          }
        ) predecessors;

        machineConfig =
          { lib, ... }:
          {
            boot.kernelVersion = lib.mkForce kernelVersion;
            services.live-patches.enable = true;
            runit.services.live-patches.run = lib.mkForce "sleep inf";

            environment.etc = {
              "livepatch-lifecycle/kvm-smoke".source = "${kvmSmoke}/bin/kvm_smoke";
            }
            // predecessorEtc;
          };

        mkScript =
          vendor:
          let
            predecessor = predecessors.${vendor} or null;
            expectedVendor = if vendor == "amd" then "AuthenticAMD" else "GenuineIntel";
            kvmModule = if vendor == "amd" then "kvm_amd" else "kvm_intel";
            requiredFlags = if vendor == "amd" then [ "svm" ] else [ "vmx" ];
            patchSpecificChecks = lib.optionalString (vendor == "amd" && kernelVersion == "6.12.95") ''
              machine.all_succeed(
                "grep -m1 '^flags' /proc/cpuinfo | grep -qw npt",
                "grep -m1 '^flags' /proc/cpuinfo | grep -qw nrip_save",
                "grep -Fx 'Vulnerable: Safe RET, no microcode' " \
                "/sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow",
              )
            '';
          in
          ''
            BOOT_VERSION = ${builtins.toJSON kernelVersion}
            CANDIDATE_VERSION = ${toString candidateVersion}
            CANDIDATE_NAME = ${builtins.toJSON candidateName}
            EXPECTED_VENDOR = ${builtins.toJSON expectedVendor}
            KVM_MODULE = ${builtins.toJSON kvmModule}
            KVM_SMOKE = "/etc/livepatch-lifecycle/kvm-smoke"
            REQUIRED_FLAGS = ${builtins.toJSON requiredFlags}
            PREDECESSOR_VERSION = ${builtins.toJSON (if predecessor == null then null else predecessor.version)}
            PREDECESSOR_NAME = ${builtins.toJSON (if predecessor == null then null else predecessor.moduleName)}
            PREDECESSOR_SHA256 = ${builtins.toJSON (if predecessor == null then null else predecessor.sha256)}
            PREDECESSOR_MODULE = ${
              builtins.toJSON (
                if predecessor == null then null else "/etc/livepatch-lifecycle/predecessor-${vendor}.ko"
              )
            }
            KERNEL_FAULT_PATTERN =
              /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|Invalid relocation target|disagrees about version|Unknown symbol/

            def patch_dir(name)
              "/sys/kernel/livepatch/#{name}"
            end

            def wait_for_patch(machine, name)
              dir = patch_dir(name)
              machine.wait_until_succeeds(
                "test -d #{dir} && " \
                "test \"$(cat #{dir}/enabled)\" = 1 && " \
                "test \"$(cat #{dir}/transition)\" = 0",
                timeout: 180
              )
            end

            def wait_for_inactive_patch(machine, name)
              dir = patch_dir(name)
              machine.wait_until_succeeds(
                "test ! -d #{dir} || { " \
                "test \"$(cat #{dir}/enabled)\" = 0 && " \
                "test \"$(cat #{dir}/transition)\" = 0; }",
                timeout: 180
              )
            end

            def module_release(version)
              "#{BOOT_VERSION}.#{version}"
            end

            def assert_release(machine, release)
              machine.succeeds("test \"$(uname -r)\" = #{release}")
            end

            def candidate_module(machine)
              store = machine.succeeds("cat /etc/livepatch-store-path")[1].strip
              path = "#{store}/lib/modules/#{BOOT_VERSION}/extra/#{CANDIDATE_NAME}.ko"
              machine.succeeds("test -f #{path}")
              path
            end

            def enable_patch(machine, module_path, name)
              machine.succeeds("insmod #{module_path}", timeout: 60)
              wait_for_patch(machine, name)
            end

            def disable_and_remove_patch(machine, name)
              dir = patch_dir(name)
              if machine.execute("test -e #{dir}/enabled")[0] == 0
                machine.succeeds("sh -c 'echo 0 > #{dir}/enabled'", timeout: 60)
                wait_for_inactive_patch(machine, name)
              end

              machine.succeeds("rmmod #{name}", timeout: 60)
              machine.fails("test -d /sys/module/#{name}")
              machine.fails("test -d #{dir}")
            end

            def assert_kvm_works(machine)
              machine.succeeds("modprobe #{KVM_MODULE}", timeout: 60)
              machine.wait_until_succeeds("test -c /dev/kvm", timeout: 30)
              machine.succeeds("test -d /sys/module/#{KVM_MODULE}")
              machine.succeeds(KVM_SMOKE, timeout: 60)
            end

            def assert_kernel_healthy(machine, dmesg_start)
              output = machine.succeeds("dmesg | tail -n +#{dmesg_start}")[1]
              raise "kernel fault after livepatch lifecycle:\n#{output}" if output.match?(KERNEL_FAULT_PATTERN)

              machine.succeeds("i=0; while test \"$i\" -lt 32; do sh -c : || exit 1; i=$((i + 1)); done")
              assert_kvm_works(machine)
            end

            machine.start
            machine.wait_until_online
            assert_release(machine, BOOT_VERSION)

            machine.succeeds(
              "grep -Eq '^vendor_id[[:space:]]*: #{EXPECTED_VENDOR}$' /proc/cpuinfo"
            )
            REQUIRED_FLAGS.each do |flag|
              machine.succeeds("grep -m1 '^flags' /proc/cpuinfo | grep -qw #{flag}")
            end
            ${patchSpecificChecks}

            if machine.execute("test -d /sys/module/#{KVM_MODULE}")[0] == 0
              machine.succeeds("modprobe -r #{KVM_MODULE}")
            end
            machine.fails("test -d /sys/module/#{KVM_MODULE}")

            candidate = candidate_module(machine)
            machine.all_succeed(
              "test \"$(modinfo -F name #{candidate})\" = #{CANDIDATE_NAME}",
              "modinfo -F vermagic #{candidate} | grep -q '^#{BOOT_VERSION} '",
              "mkdir -p /lib/modules",
              "ln -snf /run/current-system/kernel-modules/lib/modules/#{BOOT_VERSION} " \
              "/lib/modules/#{module_release(CANDIDATE_VERSION)}",
            )
            dmesg_start = machine.succeeds("dmesg | wc -l")[1].to_i + 1

            # Direct load and clean removal.
            enable_patch(machine, candidate, CANDIDATE_NAME)
            assert_release(machine, module_release(CANDIDATE_VERSION))
            assert_kernel_healthy(machine, dmesg_start)
            disable_and_remove_patch(machine, CANDIDATE_NAME)
            assert_release(machine, BOOT_VERSION)
            assert_kernel_healthy(machine, dmesg_start)

            unless PREDECESSOR_MODULE.nil?
              machine.all_succeed(
                "test \"$(sha256sum #{PREDECESSOR_MODULE} | cut -d' ' -f1)\" = #{PREDECESSOR_SHA256}",
                "test \"$(modinfo -F name #{PREDECESSOR_MODULE})\" = #{PREDECESSOR_NAME}",
                "modinfo -F vermagic #{PREDECESSOR_MODULE} | grep -q '^#{BOOT_VERSION} '",
                "ln -snf /run/current-system/kernel-modules/lib/modules/#{BOOT_VERSION} " \
                "/lib/modules/#{module_release(PREDECESSOR_VERSION)}",
              )

              # Compatible cumulative replacement.
              enable_patch(machine, PREDECESSOR_MODULE, PREDECESSOR_NAME)
              assert_release(machine, module_release(PREDECESSOR_VERSION))
              enable_patch(machine, candidate, CANDIDATE_NAME)
              wait_for_inactive_patch(machine, PREDECESSOR_NAME)
              assert_release(machine, module_release(CANDIDATE_VERSION))
              assert_kernel_healthy(machine, dmesg_start)

              machine.succeeds("rmmod #{PREDECESSOR_NAME}", timeout: 60)
              machine.fails("test -d /sys/module/#{PREDECESSOR_NAME}")

              # An unaware older cumulative patch must be rejected cleanly.
              status, output = machine.execute("insmod #{PREDECESSOR_MODULE}", timeout: 60)
              raise "downgrade unexpectedly succeeded:\n#{output}" if status == 0

              machine.fails("test -d /sys/module/#{PREDECESSOR_NAME}")
              wait_for_patch(machine, CANDIDATE_NAME)
              assert_release(machine, module_release(CANDIDATE_VERSION))
              assert_kernel_healthy(machine, dmesg_start)

              disable_and_remove_patch(machine, CANDIDATE_NAME)
              assert_release(machine, BOOT_VERSION)
              assert_kernel_healthy(machine, dmesg_start)
            end
          '';
      in
      assert candidateVersion > 0;
      {
        name = "kernel-livepatch-lifecycle-${kernelVersion}";

        description = ''
          Validate the active ${kernelVersion} livepatch lifecycle on real x86 host CPUs
        '';

        machines = {
          machine = import ../../machines/vpsadminos/with-empty.nix {
            inherit pkgs;
            config = machineConfig;
          };
        };

        testScripts = {
          amd = {
            description = "Load, replace, reject downgrade, and unload on AMD";
            tags = [
              "livepatch-lifecycle"
              "livepatch-amd"
            ];
            labels.cpuVendor = "amd";
            script = mkScript "amd";
          };

          intel = {
            description = "Load, replace, reject downgrade, and unload on Intel";
            tags = [
              "livepatch-lifecycle"
              "livepatch-intel"
            ];
            labels.cpuVendor = "intel";
            script = mkScript "intel";
          };
        };
      };
  }
)

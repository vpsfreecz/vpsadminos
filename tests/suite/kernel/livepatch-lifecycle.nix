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

        machineConfig =
          { lib, ... }:
          {
            imports = lib.optional (line ? bootModule) line.bootModule;
            boot.kernelVersion = lib.mkForce kernelVersion;
            services.live-patches.enable = true;
            runit.services.live-patches.run = lib.mkForce "sleep inf";

            environment.etc."livepatch-lifecycle/kvm-smoke".source = "${kvmSmoke}/bin/kvm_smoke";
          };

        mkNativeScript =
          vendor:
          let
            expectedVendor = if vendor == "amd" then "AuthenticAMD" else "GenuineIntel";
            kvmModule = if vendor == "amd" then "kvm_amd" else "kvm_intel";
            requiredFlags = if vendor == "amd" then [ "svm" ] else [ "vmx" ];
          in
          ''
            BOOT_VERSION = ${builtins.toJSON kernelVersion}
            EXPECTED_VENDOR = ${builtins.toJSON expectedVendor}
            KVM_MODULE = ${builtins.toJSON kvmModule}
            KVM_SMOKE = "/etc/livepatch-lifecycle/kvm-smoke"
            REQUIRED_FLAGS = ${builtins.toJSON requiredFlags}
            NFS_CONTROLS = "/sys/fs/nfs/net/nfs_client"
            KERNEL_FAULT_PATTERN =
              /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|Invalid relocation target|disagrees about version|Unknown symbol|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall/

            machine.start
            machine.wait_until_online
            dmesg_start = machine.succeeds("dmesg | wc -l")[1].to_i + 1
            machine.succeeds("test \"$(uname -r)\" = #{BOOT_VERSION}")
            machine.succeeds(
              "grep -Eq '^vendor_id[[:space:]]*: #{EXPECTED_VENDOR}$' /proc/cpuinfo"
            )
            REQUIRED_FLAGS.each do |flag|
              machine.succeeds("grep -m1 '^flags' /proc/cpuinfo | grep -qw #{flag}")
            end

            # Native continuity: no livepatch is present or loadable.
            machine.succeeds("test -z \"$(ls -A /sys/kernel/livepatch 2>/dev/null)\"")

            # Assert the native ABI. The NFS harness owns the full sysfs and
            # behavioral continuity rows.
            machine.wait_until_succeeds(
              "test -r #{NFS_CONTROLS}/shutdown && " \
                "test -r #{NFS_CONTROLS}/shutdown_tree",
              timeout: 30,
            )
            machine.all_succeed(
              "test \"$(cat #{NFS_CONTROLS}/shutdown)\" = 0",
              "test \"$(cat #{NFS_CONTROLS}/shutdown_tree)\" = 0",
            )

            machine.succeeds("modprobe #{KVM_MODULE}", timeout: 60)
            machine.wait_until_succeeds("test -c /dev/kvm", timeout: 30)
            machine.succeeds(KVM_SMOKE, timeout: 60)

            output = machine.succeeds("dmesg | tail -n +#{dmesg_start}")[1]
            raise "kernel fault during native .110 continuity:\n#{output}" if output.match?(KERNEL_FAULT_PATTERN)
          '';
      in
      assert line.native or false;
      {
        name = "kernel-livepatch-lifecycle-${instance}";
        description = "Validate native ${kernelVersion} continuity on real x86 host CPUs";

        machines.machine = import ../../machines/vpsadminos/with-empty.nix {
          inherit pkgs;
          config = machineConfig;
        };

        testScripts = {
          amd = {
            description = "Validate native continuity on AMD";
            tags = [
              "livepatch-lifecycle"
              "livepatch-amd"
            ];
            labels.cpuVendor = "amd";
            script = mkNativeScript "amd";
          };

          intel = {
            description = "Validate native continuity on Intel";
            tags = [
              "livepatch-lifecycle"
              "livepatch-intel"
            ];
            labels.cpuVendor = "intel";
            script = mkNativeScript "intel";
          };
        };
      };
  }
)

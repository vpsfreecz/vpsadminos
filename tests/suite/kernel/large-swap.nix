import ../../make-template.nix (
  { cgroupsVersion, kernelSeries }:
  {
    instance = "${kernelSeries}-cgroups-v${toString cgroupsVersion}";

    test =
      { pkgs }:
      let
        lib = pkgs.lib;
        kernels = import ../../../os/packages/linux/available-kernels.nix { inherit lib; };
        kernelVersion =
          if kernelSeries == "stable" then
            kernels.stableKernelVersion
          else if kernelSeries == "unstable" then
            kernels.unstableKernelVersion
          else
            throw "unsupported large-swap kernel series: ${kernelSeries}";
      in
      {
        name = "kernel-large-swap-${kernelSeries}-cgroups-v${toString cgroupsVersion}";
        description = "Activate and deactivate swap with large per-page metadata";
        tags = [ "ci" ];

        machine =
          (import ../../machines/vpsadminos/with-empty.nix {
            inherit pkgs;
            config =
              { lib, ... }:
              {
                boot.kernelVersion = lib.mkOverride 0 kernelVersion;
                boot.enableUnifiedCgroupHierarchy = lib.mkOverride 0 (cgroupsVersion == 2);
                boot.qemu.memory = lib.mkOverride 0 2048;
                boot.qemu.cpus = lib.mkOverride 0 2;
                boot.qemu.cpu.cores = lib.mkOverride 0 2;
                boot.qemu.cpu.threads = lib.mkOverride 0 1;
                boot.qemu.cpu.sockets = lib.mkOverride 0 1;
              };
          })
          // {
            # The sparse disk needs an 8 MiB proactive-swap bitmap with 4 KiB
            # pages. Its metadata must not require physically contiguous memory.
            disks = [
              {
                type = "file";
                device = "{machine}-swap.img";
                size = "256G";
              }
            ];
          };

        testScript = ''
          machine.start
          machine.succeeds("mkswap /dev/sda")

          2.times do
            swap_status, swap_output = machine.execute("swapon /dev/sda", timeout: 180)
            puts machine.succeeds("dmesg")[1] unless swap_status.zero?
            expect(swap_status).to eq(0), swap_output
            entries = machine.succeeds("cat /proc/swaps")[1].lines.drop(1).map(&:split)
            expect(entries.length).to eq(1)
            expect(entries[0][0]).to eq("/dev/sda")
            expect(entries[0][2].to_i).to be > 255 * 1024 * 1024

            machine.succeeds("swapoff /dev/sda", timeout: 180)
            expect(machine.succeeds("cat /proc/swaps")[1].lines.length).to eq(1)
          end

          expect(machine.succeeds("dmesg")[1]).not_to include(
            "couldn't allocate enough memory for swap_cgroup"
          )
          expect(machine.succeeds("cat /proc/sys/kernel/tainted")[1].to_i & 512).to eq(0)
        '';
      };
  }
)

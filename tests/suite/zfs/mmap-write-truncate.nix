import ../../make-test.nix (
  { pkgs }:
  {
    name = "zfs-mmap-write-truncate";

    description = ''
      Verify faulted mmap-source writes finish and release their range locks.
      Exercise the exact pinned ZFS helper on both ZFS and OverlayFS in a VM.
      An unavailable kernel userfaultfd is a failure, not skipped CI coverage.
    '';

    tags = [
      "ci"
      "regression"
    ];

    machine = import ../../machines/vpsadminos/with-tank.nix {
      inherit pkgs;
      config =
        {
          config,
          pkgs,
          lib,
          ...
        }:
        let
          kernelPackages = import ../../../os/packages/linux/packages.nix {
            inherit config pkgs lib;
          };
          zfsUserWithTests =
            (kernelPackages.genZfsUserPackage config.boot.kernelVersion).overrideAttrs
              (old: {
                postInstall =
                  lib.replaceStrings
                    [ "rm -rf $out/share/zfs/zfs-tests" ]
                    [ "echo 'keeping zfs-tests for mmap-write-truncate'" ]
                    (old.postInstall or "");
              });
        in
        {
          boot.zfsUserPackage = lib.mkForce zfsUserWithTests;
          boot.kernelModules = [ "overlay" ];
          boot.kernel.sysctl."vm.unprivileged_userfaultfd" = 1;
        };
    };

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool('tank', timeout: 300)

      _, root = machine.succeeds(
        'dirname "$(dirname "$(readlink -f "$(command -v zfs)")")"'
      )
      helper = "#{root.strip}/share/zfs/zfs-tests/bin/mmap_write_truncate"
      machine.succeeds("test -x #{helper}")
      machine.all_succeed(
        'zfs create -o recordsize=128K -o mountpoint=/mmap-write-truncate tank/mmap-write-truncate',
        'mkdir -p /mmap-write-truncate/direct /mmap-write-truncate/lower /mmap-write-truncate/upper /mmap-write-truncate/work /mnt/mmap-write-truncate',
        'mount -t overlay overlay -o lowerdir=/mmap-write-truncate/lower,upperdir=/mmap-write-truncate/upper,workdir=/mmap-write-truncate/work /mnt/mmap-write-truncate'
      )

      ['/mmap-write-truncate/direct', '/mnt/mmap-write-truncate'].each do |dir|
        machine.succeeds(
          "timeout --kill-after=5 60 #{helper} #{dir}/source #{dir}/destination",
          timeout: 75
        )
      end

      machine.all_succeed(
        'umount /mnt/mmap-write-truncate',
        'zfs destroy tank/mmap-write-truncate'
      )
    '';
  }
)

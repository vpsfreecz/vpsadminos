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

    machine = import ../../machines/vpsadminos/tank.nix {
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
              postInstall = lib.replaceStrings
                [ "rm -rf $out/share/zfs/zfs-tests" ]
                [ "echo 'keeping zfs-tests for zfs-full-suite'" ]
                (old.postInstall or "");
            }
          );
        in
        {
          boot.zfsUserPackage = lib.mkForce zfsUserWithTests;

          # zfs-tests.sh requires ksh and passwordless sudo for the run user.
          environment.systemPackages = [
            pkgs.ksh
            pkgs.sudo
          ];
        };
    };

    testScript = ''
      machine.start
      machine.wait_for_osctl_pool('tank')

      _, zfs_tests_path = machine.succeeds('command -v zfs-tests.sh')
      zfs_tests_path = zfs_tests_path.strip

      if zfs_tests_path.empty?
        raise 'zfs-tests.sh not found in guest PATH'
      end

      machine.all_succeed(
        "test -x #{zfs_tests_path}",
        "test -x /run/current-system/sw/share/zfs/test-runner/bin/test-runner.py",
        "test -d /run/current-system/sw/share/zfs/zfs-tests",
        "test -f /run/current-system/sw/share/zfs/zfs-tests/include/default.cfg"
      )

      machine.all_succeed(
        "id -u zfstest >/dev/null 2>&1 || useradd -m zfstest",
        "printf 'zfstest ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/90-zfstest",
        "chmod 0440 /etc/sudoers.d/90-zfstest",
        "mkdir -p /var/tmp/zfs-full-suite",
        "chmod 1777 /var/tmp/zfs-full-suite"
      )

      profile = ENV.fetch('VPSADMINOS_ZFS_FULL_PROFILE', 'full')

      case profile
      when 'full'
        cmd = "cd /var/tmp/zfs-full-suite && #{zfs_tests_path} -v -q -x -d /var/tmp/zfs-full-suite -r common.run,linux.run -T functional"
        timeout = 6 * 60 * 60
      when 'sanity'
        cmd = "cd /var/tmp/zfs-full-suite && #{zfs_tests_path} -v -q -x -d /var/tmp/zfs-full-suite -r sanity.run -T functional"
        timeout = 3 * 60 * 60
      when 'smoke'
        cmd = "cd /var/tmp/zfs-full-suite && #{zfs_tests_path} -v -q -x -f -d /var/tmp/zfs-full-suite -t tests/functional/cli_root/zfs_create/zfs_create_001_pos.ksh"
        timeout = 60 * 60
      else
        raise "Unsupported VPSADMINOS_ZFS_FULL_PROFILE=#{profile.inspect}, expected full|sanity|smoke"
      end

      machine.succeeds("su - zfstest -c #{cmd.inspect}", timeout: timeout)
    '';
  }
)

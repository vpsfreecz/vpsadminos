import ../../make-template.nix (
  { cgroupVersion }:
  {
    instance = "v${toString cgroupVersion}";
    test = { pkgs }: {
      name = "osctl-forced-stop-legacy";
      description = "Forced stopping without the NFS cancellation tree control";
      tags = [ "ci" ];
      machine = import ../../machines/vpsadminos/with-tank.nix {
        inherit pkgs;
        config = {
          boot.kernelVersion = "6.12.48";
          boot.enableUnifiedCgroupHierarchy = cgroupVersion == 2;
        };
      };
      testScript = ''
        before(:suite) do
          machine.start
          machine.wait_for_osctl_pool('tank')
          machine.wait_until_online
          machine.succeeds('modprobe nfs')
          machine.succeeds('test ! -e /sys/fs/nfs/net/nfs_client/shutdown_tree')
          machine.succeeds('osctl ct new --distribution alpine legacy')
          machine.succeeds('osctl ct unset start-menu legacy')
        end

        describe 'forced stopping on an older kernel', order: :defined do
          [false, true].each do |frozen|
            it "kills a container without NFS (frozen: #{frozen})" do
              machine.succeeds('osctl ct start legacy')
              machine.succeeds('osctl ct freeze legacy') if frozen
              machine.succeeds('sv -w 60 restart osctld', timeout: 90)
              machine.wait_for_osctl_pool('tank')
              start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              machine.succeeds('osctl ct stop --kill legacy', timeout: 70)
              expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 65
              expect(machine.succeeds('osctl ct show -H -o state legacy')[1].strip).to eq('stopped')
              machine.succeeds('osctl ct start legacy')
              machine.succeeds('osctl ct exec legacy sh -c "echo recovered > /root/recovered"')
              expect(machine.succeeds('osctl ct exec legacy cat /root/recovered')[1].strip).to eq('recovered')
              machine.succeeds('osctl ct stop --kill legacy', timeout: 70)
            end
          end
        end
      '';
    };
  }
)

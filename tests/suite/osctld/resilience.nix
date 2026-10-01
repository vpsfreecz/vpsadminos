import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctld-resilience";

    description = ''
      Test osctld resilience to unexpected container state
    '';

    tags = [ "ci" ];

    machine = import ../../machines/vpsadminos/tank.nix pkgs;

    testScript = ''
      require 'shellwords'

      OSCTLD_SOCKET = '/run/osctl/osctld.sock'

      ctid = get_container_id('missing-rootfs')

      configure_examples do |config|
        config.default_order = :defined
      end

      def self.output_of(command)
        machine.succeeds(command)[1].strip
      end

      def self.wait_osctld_ready
        machine.wait_for_service('osctld')
        machine.wait_until_succeeds("test -S #{OSCTLD_SOCKET}", timeout: 60)
        machine.wait_for_osctl_pool('tank')
      end

      def self.restart_osctld
        machine.succeeds('sv -w 60 restart osctld')
        wait_osctld_ready
      end

      def self.ct_state(ctid)
        machine.osctl_json("ct show #{ctid}")['state']
      end

      def self.ct_info(ctid)
        machine.osctl_json("ct show #{ctid}")
      end

      def self.ct_dataset(ctid)
        output_of("osctl ct show -H -o dataset #{Shellwords.escape(ctid)}")
      end

      def self.shared_dir_path(ctid)
        "/run/osctl/pools/tank/mounts/#{ctid}"
      end

      def self.wait_ct_running(ctid)
        wait_for_block(name: "#{ctid} becomes running", timeout: 120) do
          ct_state(ctid) == 'running'
        end

        machine.wait_until_succeeds("osctl ct exec #{Shellwords.escape(ctid)} true", timeout: 120)
      end

      def self.trash_dataset(dataset)
        escaped_dataset = Shellwords.escape(dataset)
        trashed_dataset = "#{dataset}-trashed"
        escaped_trashed_dataset = Shellwords.escape(trashed_dataset)

        machine.succeeds(<<~SH)
          set -eu
          zfs destroy -r -f #{escaped_trashed_dataset} >/dev/null 2>&1 || true
          zfs rename -u #{escaped_dataset} #{escaped_trashed_dataset}
          ! zfs list -H #{escaped_dataset}
        SH

        trashed_dataset
      end

      def self.expect_osctld_operational
        machine.succeeds("test -S #{OSCTLD_SOCKET}")
        machine.succeeds('osctl pool ls')
      end

      before(:suite) do
        machine.start
        wait_osctld_ready
        machine.wait_until_online
      end

      describe 'running container with a missing rootfs dataset', order: :defined do
        before(:context) do
          machine.execute("osctl ct del -f --prune #{Shellwords.escape(ctid)} >/dev/null 2>&1 || true")
          machine.all_succeed(
            "osctl ct new --distribution alpine #{Shellwords.escape(ctid)}",
            "osctl ct unset start-menu #{Shellwords.escape(ctid)}",
            "osctl ct start #{Shellwords.escape(ctid)}"
          )
          wait_ct_running(ctid)
          @dataset = ct_dataset(ctid)
          @lxc_path = ct_info(ctid)['lxc_path']
          @deleted = false
        end

        after(:context) do
          unless @deleted
            machine.execute("zfs rename -u #{Shellwords.escape(@trashed_dataset)} #{Shellwords.escape(@dataset)} >/dev/null 2>&1 || true") if @dataset && @trashed_dataset
            machine.execute("osctl ct del -f --prune #{Shellwords.escape(ctid)} >/dev/null 2>&1 || true")
          end
          machine.execute("lxc-stop -k -P #{Shellwords.escape(@lxc_path)} -n #{Shellwords.escape(ctid)} >/dev/null 2>&1 || true") if @lxc_path
          machine.execute("zfs destroy -r -f #{Shellwords.escape(@dataset)} >/dev/null 2>&1 || true") if @dataset
          machine.execute("zfs destroy -r -f #{Shellwords.escape(@trashed_dataset)} >/dev/null 2>&1 || true") if @trashed_dataset
        end

        it 'starts from a running container' do
          expect(ct_state(ctid)).to eq('running')
          expect(output_of("zfs list -H -o name #{Shellwords.escape(@dataset)}")).to eq(@dataset)
        end

        it 'keeps osctld operational after the live dataset disappears' do
          @trashed_dataset = trash_dataset(@dataset)

          expect_osctld_operational
        end

        it 'survives osctld restart and reports the container as errored' do
          restart_osctld

          expect_osctld_operational
          expect(ct_state(ctid)).to eq('error')
        end

        it 'deletes the errored container while its original dataset is absent' do
          machine.succeeds("osctl ct del -f --prune #{Shellwords.escape(ctid)}")
          @deleted = true

          expect(machine.execute("osctl ct show #{Shellwords.escape(ctid)} >/dev/null 2>&1")[0]).not_to eq(0)
          expect_osctld_operational
        end
      end

      describe 'explicit recovery after host-link ownership is lost' do
        it 'preserves replacement links and acknowledges absence without rebooting' do
          recover_ct = get_container_id('host-link-recovery')
          machine.all_succeed(
            "osctl ct new --distribution alpine #{recover_ct}",
            "osctl ct unset start-menu #{recover_ct}",
            "osctl ct netif new routed #{recover_ct} eth0",
            "osctl ct netif ip add #{recover_ct} eth0 192.0.2.70/32",
            "osctl ct start #{recover_ct}",
          )
          wait_ct_running(recover_ct)
          netif = machine.osctl_json("ct netif ls #{recover_ct}").find { |v| v.fetch('name') == 'eth0' }
          veth = netif.fetch('veth')
          machine.fails("osctl ct recover forget-host-link #{recover_ct} eth0")

          # Simulate host-side loss while osctld still owns the recorded link.
          machine.succeeds("ip link delete #{veth}")
          machine.succeeds("osctl ct stop #{recover_ct}")
          expect(ct_state(recover_ct)).to eq('stopped')
          expect(ct_info(recover_ct).fetch('recovery_tainted')).to be(true)
          machine.fails("osctl ct start #{recover_ct}")
          restart_osctld
          expect(ct_info(recover_ct).fetch('recovery_tainted')).to be(true)

          machine.succeeds("ip link add #{veth} type dummy")
          replacement_index = output_of("cat /sys/class/net/#{veth}/ifindex")
          machine.fails("osctl ct recover forget-host-link #{recover_ct} eth0")
          expect(output_of("cat /sys/class/net/#{veth}/ifindex")).to eq(replacement_index)
          machine.fails("osctl ct recover cleanup #{recover_ct}")
          expect(output_of("cat /sys/class/net/#{veth}/ifindex")).to eq(replacement_index)

          machine.succeeds("ip link delete #{veth}")
          machine.succeeds("osctl ct recover forget-host-link #{recover_ct} eth0")
          expect(ct_info(recover_ct).fetch('recovery_tainted')).to be(true)
          machine.succeeds("osctl ct recover cleanup #{recover_ct}")
          expect(ct_info(recover_ct).fetch('recovery_tainted')).to be(false)
          expect(ct_state(recover_ct)).to eq('stopped')
          machine.succeeds("osctl ct start #{recover_ct}")
          wait_ct_running(recover_ct)
          machine.succeeds("osctl ct del -f --prune #{recover_ct}")
        end
      end

      describe 'container delete with a stale shared directory', order: :defined do
        delete_ctid = get_container_id('stale-shared-dir')

        before(:context) do
          machine.execute("osctl ct del -f --prune #{Shellwords.escape(delete_ctid)} >/dev/null 2>&1 || true")
          machine.all_succeed(
            "osctl ct new --distribution alpine #{Shellwords.escape(delete_ctid)}",
            "osctl ct unset start-menu #{Shellwords.escape(delete_ctid)}"
          )
        end

        after(:context) do
          machine.execute("osctl ct del -f --prune #{Shellwords.escape(delete_ctid)} >/dev/null 2>&1 || true")
        end

        it 'does not fail on a stale non-mounted child directory' do
          shared_dir = shared_dir_path(delete_ctid)

          machine.succeeds("mkdir -p #{Shellwords.escape(File.join(shared_dir, 'stale'))}")
          expect(machine.execute("mountpoint -q #{Shellwords.escape(shared_dir)}")[0]).not_to eq(0)

          machine.succeeds("osctl ct del -f --prune #{Shellwords.escape(delete_ctid)}")
          expect(machine.execute("test -e #{Shellwords.escape(shared_dir)}")[0]).not_to eq(0)
          expect_osctld_operational
        end
      end
      describe 'bounded repeated container cleanup', order: :defined do
        it 'reclaims distinct container resources without restarting osctld' do
          sibling = get_container_id('cleanup-sibling')
          machine.all_succeed(
            "osctl ct new --distribution alpine #{sibling}",
            "osctl ct unset start-menu #{sibling}",
            "osctl ct start #{sibling}",
            "osctl ct exec #{sibling} sh -c 'echo retained > /root/cleanup-marker'"
          )
          sibling_init = ct_info(sibling).fetch('init_pid')

          supervisor = output_of('sv status osctld').match(/\(pid (\d+)\)/).captures.first
          daemon_pids = output_of("pgrep -P #{supervisor} -f '^osctld: main$'").split
          expect(daemon_pids.length).to eq(1)
          daemon_pid = daemon_pids.first
          daemon_started = output_of("awk '{print $22}' /proc/#{daemon_pid}/stat")
          fd_counts = []

          # Twelve different root datasets, mounts, cgroups, BPF mounts and
          # init PIDs expose accumulation that a recycled identity would not.
          # A live sibling must stay healthy; no throughput target is set.
          12.times do |index|
            current = get_container_id(format('cleanup-%02d', index))
            machine.all_succeed(
              "osctl ct new --distribution alpine #{current}",
              "osctl ct unset start-menu #{current}",
              "osctl ct start #{current}",
              "osctl ct exec #{current} sh -c 'echo round-#{index} > /root/churn-marker'"
            )
            info = ct_info(current)
            dataset = ct_dataset(current)
            init_pid = info.fetch('init_pid')
            init_started = output_of("awk '{print $22}' /proc/#{init_pid}/stat")
            cgroup = "/run/osctl/cgroup/#{info.fetch('group_path')}"
            bpffs = "/run/osctl/ct-bpf/tank/#{current}"
            machine.all_succeed(
              "test -d #{Shellwords.escape(cgroup)}",
              "test -d #{Shellwords.escape(bpffs)}",
              "osctl ct stop #{current}",
              "osctl ct start #{current}",
              "osctl ct exec #{current} grep -Fx round-#{index} /root/churn-marker",
              "osctl ct stop #{current}",
              "osctl ct del --prune #{current}"
            )
            machine.wait_until_succeeds(
              "test ! -e #{Shellwords.escape(cgroup)} && " \
              "test ! -e #{Shellwords.escape(bpffs)} && " \
              "test ! -e #{Shellwords.escape(shared_dir_path(current))} && " \
              "! zfs list -H #{Shellwords.escape(dataset)} >/dev/null 2>&1",
              timeout: 60
            )
            expect(machine.execute("osctl ct show #{current} >/dev/null 2>&1")[0]).not_to eq(0)
            old_init = machine.execute("awk '{print $22}' /proc/#{init_pid}/stat 2>/dev/null")[1].strip
            expect(old_init).not_to eq(init_started)
            expect(ct_info(sibling).fetch('init_pid')).to eq(sibling_init)
            machine.succeeds("osctl ct exec #{sibling} grep -Fx retained /root/cleanup-marker")
            expect(output_of("awk '{print $22}' /proc/#{daemon_pid}/stat")).to eq(daemon_started)
            fd_counts << Integer(output_of("ls -U /proc/#{daemon_pid}/fd | wc -l"))
          end

          # The first cycle warms lazy descriptors; later cycles must return
          # to that count instead of retaining one per container identity.
          expect(fd_counts.drop(1).max).to be <= fd_counts.first
          machine.all_succeed(
            "osctl ct exec #{sibling} grep -Fx retained /root/cleanup-marker",
            "osctl ct stop #{sibling}",
            "osctl ct del --prune #{sibling}"
          )
        end
      end

      describe 'quota-limited image import cleanup', order: :defined do
        it 'reclaims the partial container and permits a clean retry' do
          failed = get_container_id('quota-import')
          escaped_id = Shellwords.escape(failed)
          dataset = "tank/ct/#{failed}"
          escaped_dataset = Shellwords.escape(dataset)
          expect(machine.execute("osctl user show #{escaped_id} >/dev/null 2>&1")[0]).not_to eq(0)

          # Restrict only this new CT's dataset, not the pool or VM disk. The
          # same existing import path must reach rootfs extraction and fail
          # with a real storage limit, rather than an invalid CLI option.
          status, stdout, stderr = machine.execute(
            "osctl ct new --distribution alpine --zfs-property refquota=1M #{escaped_id}"
          )
          expect(status).not_to eq(0)
          expect(stdout).to include('Importing rootfs')
          expect("#{stdout}\n#{stderr}").to match(/space|quota|ENOSPC/i)

          machine.wait_until_succeeds(
            "! zfs list -H #{escaped_dataset} >/dev/null 2>&1 && " \
            "! osctl ct show #{escaped_id} >/dev/null 2>&1 && " \
            "test ! -e #{Shellwords.escape(shared_dir_path(failed))} && " \
            "test ! -e /run/osctl/ct-bpf/tank/#{escaped_id}",
            timeout: 60
          )
          expect(output_of("find /run/osctl/cgroup -name #{Shellwords.escape("ct.#{failed}")} -print")).to be_empty
          expect(machine.execute("osctl user show #{escaped_id} >/dev/null 2>&1")[0]).not_to eq(0)

          machine.all_succeed(
            "osctl ct new --distribution alpine #{escaped_id}",
            "osctl ct unset start-menu #{escaped_id}",
            "osctl ct start #{escaped_id}",
            "osctl ct exec #{escaped_id} sh -c 'echo recovered > /root/retry-marker'",
            "osctl ct exec #{escaped_id} grep -Fx recovered /root/retry-marker",
            "osctl ct stop #{escaped_id}",
            "osctl ct del --prune #{escaped_id}"
          )
          machine.succeeds("! zfs list -H #{escaped_dataset} >/dev/null 2>&1")
        end
      end
    '';
  }
)

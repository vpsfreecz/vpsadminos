import ../../make-test.nix (
  { pkgs }:
  {
    name = "osctld-resilience";

    description = ''
      Test osctld resilience to unexpected container state
    '';

    tags = [ "ci" ];

    machine =
      let
        base = import ../../machines/vpsadminos/tank.nix pkgs;
      in
      base
      // {
        config = base.config // {
          system.extraDependencies = [ pkgs.bpftools ];
        };
        # Leave the second disk blank until the final pooled example, so the
        # original single-pool cases retain their original default pool.
        disks = base.disks ++ [
          {
            type = "file";
            device = "{machine}-sdb.img";
            size = "4G";
          }
        ];
      };

    testScript = ''
      require 'shellwords'
      require 'json'

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
          fd_snapshots = []

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
            fd_snapshots << machine.execute("ls -l /proc/#{daemon_pid}/fd")[1]
            next if fd_counts.length == 1 || fd_counts.last <= fd_counts.first

            # An osctl request can leave an IPC socket in flight at the
            # immediate sample. Require three consecutive idle samples back
            # at the warmed first-cycle count; a retained FD still fails.
            begin
              machine.wait_until_succeeds(
                "for sample in 1 2 3; do " \
                "test \"$(awk '{print $22}' /proc/#{daemon_pid}/stat 2>/dev/null)\" = #{daemon_started} && " \
                "test \"$(ls -U /proc/#{daemon_pid}/fd | wc -l)\" -le #{fd_counts.first} || exit 1; " \
                "sleep 1; done",
                timeout: 30
              )
            rescue OsVm::TimeoutError
              warn "osctld post-cycle FD counts: #{fd_counts.inspect}"
              warn "osctld FDs after first cycle:\n#{fd_snapshots.first}"
              warn "osctld FDs at peak:\n#{fd_snapshots[fd_counts.index(fd_counts.max)]}"
              warn "osctld FDs after latest cycle:\n#{fd_snapshots.last}"
              raise
            end
          end
          machine.all_succeed(
            "osctl ct exec #{sibling} grep -Fx retained /root/cleanup-marker",
            "osctl ct stop #{sibling}",
            "osctl ct del --prune #{sibling}"
          )
        end
      end

      describe 'bounded pooled cleanup with live I/O', order: :defined do
        it 'isolates paired identities and reclaims processes and quota failures' do
          machine.all_succeed(
            'test -b /dev/sdb',
            'zpool create -o feature@block_cloning=disabled dozer /dev/sdb',
            # Installing also imports the osctld pool.
            'osctl pool install dozer'
          )
          pools = %w[tank dozer]
          retained = get_container_id('pooled-retained')
          retained_inits = {}
          dataset_bases = {}
          pool_info = lambda do |pool, id|
            info = machine.osctl_json("--pool #{pool} ct show #{id}")
            expect(info.fetch('pool')).to eq(pool)
            info
          end
          pool_dataset = lambda do |pool, id|
            output_of("osctl --pool #{pool} ct show -H -o dataset #{id}")
          end

          pools.each do |pool|
            cli = "osctl --pool #{pool} ct"
            machine.all_succeed(
              "#{cli} new --distribution alpine #{retained}",
              "#{cli} unset start-menu #{retained}",
              "#{cli} start #{retained}"
            )
            retained_inits[pool] = pool_info.call(pool, retained).fetch('init_pid')
            dataset_bases[pool] = File.dirname(pool_dataset.call(pool, retained))
            machine.succeeds("#{cli} exec #{retained} sh -c #{<<~IO.shellescape}")
              set -eu
              printf '%s\\n' #{pool.shellescape} > /root/pool-identity
              cat > /root/live-io.sh <<'WORKER'
              set -eu
              trap "" HUP
              counter=0
              while :; do
                dd if=/dev/zero of=/root/live-io.block bs=4096 count=8 2>/dev/null
                counter=$((counter + 1))
                printf '%s\\n' "$counter" > /root/live-io.counter.next
                mv /root/live-io.counter.next /root/live-io.counter
                sleep 0.1
              done
              WORKER
              sh /root/live-io.sh > /root/live-io.log 2>&1 < /dev/null &
              echo $! > /root/live-io.pid
            IO
            machine.wait_until_succeeds("#{cli} exec #{retained} test -s /root/live-io.counter", timeout: 60)
          end
          expect(retained_inits.fetch('tank')).not_to eq(retained_inits.fetch('dozer'))

          supervisor = output_of('sv status osctld').match(/\(pid (\d+)\)/).captures.first
          daemon_pids = output_of("pgrep -P #{supervisor} -f '^osctld: main$'").split
          expect(daemon_pids.length).to eq(1)
          daemon_pid = daemon_pids.first
          daemon_started = output_of("awk '{print $22}' /proc/#{daemon_pid}/stat")
          fd_counts = []
          fd_snapshots = []

          # Count kernel objects as well as pins: unlinked leaked references
          # must not be mistaken for successful per-container BPF cleanup.
          bpf_counts = []
          count_bpf = lambda do
            %w[prog map link].to_h do |kind|
              records = JSON.parse(output_of("${pkgs.bpftools}/bin/bpftool -j #{kind} show"))
              expect(records).to be_a(Array)
              [kind, records.length]
            end
          end

          # Reuse the existing twelve-cycle bound, with two simultaneously live
          # pool-qualified copies per cycle, child processes and real data I/O.
          12.times do |index|
            current = get_container_id(format('pooled-%02d', index))
            identities = {}
            pools.each do |pool|
              cli = "osctl --pool #{pool} ct"
              machine.all_succeed(
                "#{cli} new --distribution alpine #{current}",
                "#{cli} unset start-menu #{current}",
                "#{cli} start #{current}"
              )
              info = pool_info.call(pool, current)
              init_pid = info.fetch('init_pid')
              identities[pool] = [init_pid, output_of("awk '{print $22}' /proc/#{init_pid}/stat")]
              machine.succeeds("#{cli} exec #{current} sh -c #{<<~IO.shellescape}")
                set -eu
                pids=""
                for number in $(seq 1 16); do
                  (dd if=/dev/zero of=/root/io.$number bs=4096 count=16 2>/dev/null) &
                  pids="$pids $!"
                done
                for pid in $pids; do wait "$pid"; done
                for number in $(seq 1 16); do test "$(wc -c < /root/io.$number)" -eq 65536; done
                sha256sum /root/io.* > /root/io.manifest
              IO
            end
            expect(identities.fetch('tank')).not_to eq(identities.fetch('dozer'))

            pools.each do |pool|
              cli = "osctl --pool #{pool} ct"
              info = pool_info.call(pool, current)
              dataset = pool_dataset.call(pool, current)
              paths = [
                "/run/osctl/cgroup/#{info.fetch('group_path')}",
                "/run/osctl/ct-bpf/#{pool}/#{current}",
                "/run/osctl/pools/#{pool}/mounts/#{current}"
              ]
              paths.first(2).each { |path| machine.succeeds("test -d #{path.shellescape}") }
              machine.all_succeed(
                "#{cli} stop #{current}",
                "#{cli} start #{current}",
                "#{cli} exec #{current} sha256sum -c /root/io.manifest"
              )
              restarted_pid = pool_info.call(pool, current).fetch('init_pid')
              restarted_identity = [restarted_pid, output_of("awk '{print $22}' /proc/#{restarted_pid}/stat")]
              expect(restarted_identity).not_to eq(identities.fetch(pool))
              machine.all_succeed(
                "#{cli} stop #{current}",
                "#{cli} del --prune #{current}"
              )
              machine.wait_until_succeeds(
                "for path in #{paths.shelljoin}; do test ! -e \"$path\" || exit 1; done; " \
                "! zfs list -H #{dataset.shellescape} >/dev/null 2>&1", timeout: 60
              )
              expect(machine.execute("#{cli} show #{current} >/dev/null 2>&1")[0]).not_to eq(0)
              expect(machine.execute("osctl --pool #{pool} user show #{current} >/dev/null 2>&1")[0]).not_to eq(0)
              [identities.fetch(pool), restarted_identity].each do |init_pid, init_started|
                expect(machine.execute("awk '{print $22}' /proc/#{init_pid}/stat 2>/dev/null")[1].strip).not_to eq(init_started)
              end
            end

            # Inject actual extraction failures while both retained I/O workers
            # are live, then retry the same identities without a daemon restart.
            if index == 5
              failed = get_container_id('pooled-quota')
              pools.each do |pool|
                cli = "osctl --pool #{pool} ct"
                dataset = "#{dataset_bases.fetch(pool)}/#{failed}"
                status, stdout, = machine.execute("#{cli} new --distribution alpine --zfs-property refquota=1M #{failed}")
                expect(status).not_to eq(0)
                expect(stdout).to include('Importing rootfs', 'Writing data stream', 'Error occurred, cleaning up')
                machine.wait_until_succeeds("grep -F 'Disk quota exceeded' /var/log/osctld | grep -F #{dataset.shellescape}", timeout: 30)
                machine.wait_until_succeeds(
                  "! zfs list -H #{dataset.shellescape} >/dev/null 2>&1 && " \
                  "test ! -e /run/osctl/pools/#{pool}/mounts/#{failed} && " \
                  "test ! -e /run/osctl/ct-bpf/#{pool}/#{failed}", timeout: 60
                )
                expect(output_of("find /run/osctl/cgroup -path '*/pool.#{pool}/*/ct.#{failed}' -print")).to be_empty
                expect(machine.execute("osctl --pool #{pool} user show #{failed} >/dev/null 2>&1")[0]).not_to eq(0)
                machine.all_succeed(
                  "#{cli} new --distribution alpine #{failed}",
                  "#{cli} unset start-menu #{failed}",
                  "#{cli} start #{failed}",
                  "#{cli} exec #{failed} sh -c 'echo recovered-#{pool} > /root/retry-marker'",
                  "#{cli} exec #{failed} grep -Fx recovered-#{pool} /root/retry-marker",
                  "#{cli} stop #{failed}",
                  "#{cli} del --prune #{failed}",
                  "! zfs list -H #{dataset.shellescape} >/dev/null 2>&1"
                )
              end
            end

            pools.each do |pool|
              cli = "osctl --pool #{pool} ct"
              expect(pool_info.call(pool, retained).fetch('init_pid')).to eq(retained_inits.fetch(pool))
              machine.succeeds("#{cli} exec #{retained} grep -Fx #{pool} /root/pool-identity")
              before = output_of("#{cli} exec #{retained} cat /root/live-io.counter")
              machine.wait_until_succeeds(
                "#{cli} exec #{retained} sh -c #{%{kill -0 "$(cat /root/live-io.pid)" && test "$(cat /root/live-io.counter)" != #{before.shellescape}}.shellescape}",
                timeout: 60
              )
            end
            expect(output_of("awk '{print $22}' /proc/#{daemon_pid}/stat")).to eq(daemon_started)
            fd_counts << Integer(output_of("ls -U /proc/#{daemon_pid}/fd | wc -l"))
            fd_snapshots << machine.execute("ls -l /proc/#{daemon_pid}/fd")[1]
            bpf_counts << count_bpf.call
            if bpf_counts.length > 1 && bpf_counts.last.any? { |kind, count| count > bpf_counts.first.fetch(kind) }
              begin
                wait_for_block(name: 'pooled BPF objects reclaimed', timeout: 30) do
                  count_bpf.call.all? { |kind, count| count <= bpf_counts.first.fetch(kind) }
                end
              ensure
                warn "pooled BPF object counts: #{bpf_counts.inspect}"
              end
            end
            next if fd_counts.length == 1 || fd_counts.last <= fd_counts.first

            begin
              machine.wait_until_succeeds(
                "for sample in 1 2 3; do " \
                "test \"$(awk '{print $22}' /proc/#{daemon_pid}/stat 2>/dev/null)\" = #{daemon_started} && " \
                "test \"$(ls -U /proc/#{daemon_pid}/fd | wc -l)\" -le #{fd_counts.first} || exit 1; " \
                "sleep 1; done", timeout: 30
              )
            rescue OsVm::TimeoutError
              warn "pooled live-I/O FD counts: #{fd_counts.inspect}"
              warn "pooled FDs after first cycle:\n#{fd_snapshots.first}"
              warn "pooled FDs at peak:\n#{fd_snapshots[fd_counts.index(fd_counts.max)]}"
              warn "pooled FDs after latest cycle:\n#{fd_snapshots.last}"
              raise
            end
          end
          warn "pooled live-I/O FD counts: #{fd_counts.inspect}"
          warn "pooled BPF object counts: #{bpf_counts.inspect}"
          pools.each do |pool|
            machine.succeeds("osctl --pool #{pool} ct del -f --prune #{retained}")
          end
        end
      end
    '';
  }
)

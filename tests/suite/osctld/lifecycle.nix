import ../../make-test.nix (
  { pkgs }:
  let
    baseMachine = import ../../machines/vpsadminos/tank.nix pkgs;
    legacySource = pkgs.fetchFromGitHub {
      owner = "vpsfreecz";
      repo = "vpsadminos";
      rev = "fc6c9fe67d7d365f26a5ab286625fd55fd5f79e1";
      hash = "sha256-NGEgkL1PyYCtOijWTdvzA/FpCF1xRz6S1GtVEwaLseY=";
    };
  in
  {
    name = "osctld-lifecycle";

    description = ''
      Test managed lifecycle authorization and residual generation recovery
    '';

    tags = [ "ci" ];

    machine = baseMachine // {
      config =
        { pkgs, ... }:
        let
          legacyOsctld = pkgs.writeShellScriptBin "legacy-osctld" ''
            export RUBYLIB="${legacySource}/osctld/lib:${legacySource}/libosctl/lib"
            exec ${pkgs.osctld}/bin/osctld "$@"
          '';
        in
        baseMachine.config
        // {
          boot.kernelModules = [ "ext4" ];
          boot.supportedFilesystems.ext4 = true;

          environment.systemPackages = [
            pkgs.e2fsprogs
            legacyOsctld
            pkgs.lvm2
            pkgs.util-linux
          ];
        };

      shells = [ "io" ];
    };

    testScript = ''
      require 'json'
      require 'shellwords'
      require 'yaml'

      DM_NAME = 'osctld-lifecycle-block'
      DM_DEVICE = "/dev/mapper/#{DM_NAME}"
      DM_IMAGE = '/tmp/osctld-lifecycle-block.img'
      DM_LOOP_FILE = '/tmp/osctld-lifecycle-block.loop'
      DM_MOUNT = '/mnt/osctld-lifecycle-block'

      def self.ensure_ready
        machine.start
        machine.wait_for_service('osctld')
        machine.wait_for_osctl_pool('tank')
        machine.wait_until_online
      end

      def self.cleanup_ct(ctid)
        machine.execute("osctl ct del -f --prune #{Shellwords.escape(ctid)}")
      end

      def self.ct_info(ctid)
        machine.osctl_json("ct show #{ctid}")
      end

      def self.lifecycle_record(ctid)
        path = "/run/osctl/pools/tank/containers/#{ctid}/lifecycle.yml"
        _, data = machine.succeeds("cat #{Shellwords.escape(path)}")
        YAML.safe_load(data)
      end

      def self.lifecycle_run(ctid, run_id)
        lifecycle_record(ctid).fetch('runs').fetch(run_id)
      end

      def self.setup_block_device
        machine.succeeds(<<~'SH')
          truncate -s 128M /tmp/osctld-lifecycle-block.img
          loopdev=$(losetup --find --show /tmp/osctld-lifecycle-block.img)
          printf '%s\n' "$loopdev" > /tmp/osctld-lifecycle-block.loop
          sectors=$(blockdev --getsz "$loopdev")
          printf '0 %s linear %s 0\n' "$sectors" "$loopdev" |
            dmsetup --noudevrules --noudevsync create osctld-lifecycle-block
          devno=$(dmsetup info -c --noheadings --separator : -o major,minor \
            osctld-lifecycle-block | tr -d ' ')
          install -d -m 755 /dev/mapper
          mknod /dev/mapper/osctld-lifecycle-block b \
            "''${devno%:*}" "''${devno#*:}"
          mkfs.ext4 -F /dev/mapper/osctld-lifecycle-block
          install -d -m 755 /mnt/osctld-lifecycle-block
          mount /dev/mapper/osctld-lifecycle-block /mnt/osctld-lifecycle-block
        SH
      end

      def self.cleanup_block_device
        machine.execute("dmsetup --noudevrules --noudevsync resume #{DM_NAME}")
        machine.execute("umount #{DM_MOUNT}")
        machine.execute("dmsetup --noudevrules --noudevsync remove #{DM_NAME}")
        machine.execute("rm -f #{DM_DEVICE}")
        machine.execute(<<~SH)
          test ! -f #{DM_LOOP_FILE} ||
            losetup -d "$(cat #{DM_LOOP_FILE})"
          rm -f #{DM_LOOP_FILE} #{DM_IMAGE}
        SH
      end

      ensure_ready

      describe 'manual lxc-start' do
        ctid = "#{get_container_id}-manual-lxc"

        before(:context) do
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct start #{ctid}",
            "osctl ct stop #{ctid}"
          )
        end

        after(:context) do
          cleanup_ct(ctid)
        end

        it 'is rejected without a managed launch authorization' do
          info = ct_info(ctid)
          command = [
            'timeout', '30',
            'lxc-start',
            '-P', info.fetch('lxc_path'),
            '-n', ctid,
            '-f', File.join(info.fetch('lxc_dir'), 'config'),
            '-F'
          ].shelljoin + ' >/tmp/manual-lxc-start.log 2>&1'
          user = "tank-#{info.fetch('user')}"

          machine.fails(
            "su -s /bin/sh #{Shellwords.escape(user)} -c " \
            "#{Shellwords.escape(command)}"
          )
          machine.succeeds(
            "grep -F 'Ignoring unowned LXC state starting for " \
              "tank:#{ctid}; manual lxc-start is unsupported' " \
              '/var/log/messages'
          )

          expect(ct_info(ctid).fetch('runtime_state')).to eq('stopped')
          expect(lifecycle_record(ctid).fetch('active_run_id')).to be_nil
        end
      end

      describe 'cpuset-constrained stopped execution' do
        ctid = "#{get_container_id}-execution"

        before(:context) do
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct cgparams set #{ctid} cpuset.cpus 0"
          )
        end

        after(:context) do
          cleanup_ct(ctid)
        end

        it 'applies the selected mask to the LXC-created namespaced root' do
          _, cpus = machine.succeeds(
            "osctl ct exec -r #{ctid} cat /sys/fs/cgroup/cpuset.cpus"
          )

          expect(cpus.strip).to eq('0')
          expect(lifecycle_record(ctid).fetch('active_run_id')).to be_nil
        end
      end

      describe 'an unkillable residual generation' do
        ctid = "#{get_container_id}-residual"
        group = "/#{ctid}-cpu"
        group_cpu_cgroup =
          "/sys/fs/cgroup/osctl/pool.tank/group.#{ctid}-cpu"

        before(:context) do
          cleanup_ct(ctid)
          machine.execute("osctl group del #{Shellwords.escape(group)}")
          cleanup_block_device
          setup_block_device
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl group new #{group}",
            "osctl group set cpu-limit #{group} 100",
            "osctl ct chgrp #{ctid} #{group}",
            "osctl ct cgparams set #{ctid} cpuset.cpus 0",
            "osctl ct mounts new --fs #{DM_MOUNT} --type bind " \
              "--opts bind,create=dir --mountpoint /mnt/blocked #{ctid}",
            "osctl ct start #{ctid}"
          )
          machine.wait_for_osctl_container(ctid)
        end

        after(:context) do
          machine.execute(
            "dmsetup --noudevrules --noudevsync resume #{DM_NAME}"
          )
          @io_thread&.join(120)

          if @old_run_id
            machine.execute(
              "osctl -j ct recover cleanup --run-id " \
              "#{Shellwords.escape(@old_run_id)} #{Shellwords.escape(ctid)}"
            )
          end

          cleanup_ct(ctid)
          machine.execute("osctl group del #{Shellwords.escape(group)}")
          cleanup_block_device
        end

        it 'quarantines the old cgroups and starts in a disjoint generation' do
          old_info = ct_info(ctid)
          @old_run_id = old_info.fetch('lifecycle_run_id')
          old_run = lifecycle_run(ctid, @old_run_id)
          old_cgroup = old_run.fetch('resources').fetch('cgroup_root')
          old_host_effects = old_run.fetch('resources').fetch('host_effects')

          machine.succeeds(
            "mkdir -p /sys/fs/cgroup/" \
              "#{Shellwords.escape(old_host_effects)}"
          )
          machine.succeeds(
            "dmsetup --noudevrules --noudevsync suspend #{DM_NAME}"
          )
          io_command = <<~SH
            printf '%s\\n' "$$" > \
              /sys/fs/cgroup/#{old_host_effects}/cgroup.procs
            exec dd if=/dev/zero of=#{DM_MOUNT}/payload \
              bs=4096 count=1 conv=fsync
          SH
          @io_thread = Thread.new do
            machine.execute(
              "/bin/sh -c #{Shellwords.escape(io_command)}",
              shell: 'io',
              timeout: 600
            )
          end
          _, io_pid = machine.wait_until_succeeds(
            "pid=$(cat /sys/fs/cgroup/" \
              "#{Shellwords.escape(old_host_effects)}/cgroup.procs) && " \
              "test \"$(ps -o comm= -p \"$pid\")\" = dd && " \
              "printf '%s\\n' \"$pid\"",
            timeout: 60
          )
          io_pid = io_pid.strip
          expect(io_pid).to match(/\A\d+\z/)

          machine.succeeds(
            "printf 'yes\\n' | osctl ct recover kill --run-id " \
              "#{Shellwords.escape(@old_run_id)} #{Shellwords.escape(ctid)}"
          )
          machine.wait_until_succeeds(
            "osctl ct recover state --no-lock --run-id " \
              "#{Shellwords.escape(@old_run_id)} #{Shellwords.escape(ctid)} " \
              ">/dev/null && " \
              "test \"$(osctl ct show -H -o runtime_state #{ctid})\" = stopped",
            timeout: 120
          )

          _, cleanup_output = machine.succeeds(
            "osctl -j ct recover cleanup --run-id #{@old_run_id} #{ctid}"
          )
          cleanup = JSON.parse(cleanup_output.lines.last)
          expect(cleanup.fetch('outcome')).to eq('quarantined')
          expect(cleanup.fetch('active_slot_released')).to be(true)
          expect(cleanup.fetch('hazards')).to include(
            'already-entered kernel or ZFS operations may complete later'
          )

          machine.succeeds("osctl ct start --wait infinity #{ctid}")
          machine.wait_for_osctl_container(ctid)
          machine.succeeds(
            "osctl ct exec #{ctid} sh -c " \
              "'printf replacement-ok > /tmp/lifecycle-generation'"
          )

          replacement_info = ct_info(ctid)
          replacement_run_id = replacement_info.fetch('lifecycle_run_id')
          replacement_run = lifecycle_run(ctid, replacement_run_id)
          replacement_cgroup =
            replacement_run.fetch('resources').fetch('cgroup_root')
          replacement_inner =
            replacement_run.fetch('resources').fetch('lxc_inner')

          expect(replacement_run_id).not_to eq(@old_run_id)
          expect(replacement_cgroup).not_to eq(old_cgroup)
          expect(replacement_info.fetch('lifecycle_residuals')).to eq(1)

          machine.succeeds(
            "osctl group set cpu-limit #{group} 200"
          )
          _, old_cpu_limit = machine.succeeds(
            "cat /sys/fs/cgroup/#{old_cgroup}/cpu.max"
          )
          _, group_cpu_limit = machine.succeeds(
            "cat #{group_cpu_cgroup}/cpu.max"
          )
          expect(old_cpu_limit.strip).to eq('100000 100000')
          expect(group_cpu_limit.strip).to eq('200000 100000')

          machine.succeeds(
            "osctl ct cgparams set #{ctid} cpuset.cpus 0-1"
          )
          _, old_mask = machine.succeeds(
            "cat /sys/fs/cgroup/#{old_cgroup}/cpuset.cpus.effective"
          )
          _, replacement_mask = machine.succeeds(
            "cat /sys/fs/cgroup/#{replacement_inner}/cpuset.cpus.effective"
          )
          expect(old_mask.strip).to eq('0')
          expect(replacement_mask.strip).to eq('0-1')
          _, replacement_nproc = machine.succeeds(
            "osctl ct exec #{ctid} nproc"
          )
          expect(replacement_nproc.strip.to_i).to eq(2)

          _, rejected = machine.fails(
            "osctl ct cgparams set #{ctid} cpuset.cpus 1"
          )
          expect(rejected).to include('residual cgroup')
          _, replacement_mask = machine.succeeds(
            "cat /sys/fs/cgroup/#{replacement_inner}/cpuset.cpus.effective"
          )
          expect(replacement_mask.strip).to eq('0-1')

          machine.succeeds(
            "dmsetup --noudevrules --noudevsync resume #{DM_NAME}"
          )
          wait_for_block(name: 'old generation is cleaned', timeout: 120) do
            status, output = machine.execute(
              "osctl -j ct recover cleanup --run-id " \
                "#{Shellwords.escape(@old_run_id)} #{Shellwords.escape(ctid)}"
            )

            if status.zero?
              result = JSON.parse(output.lines.last)
              next false unless %w[cleaned partial].include?(
                result.fetch('outcome')
              )
            elsif !output.include?('not found')
              fail "unexpected recovery cleanup failure: #{output}"
            end

            ct_info(ctid).fetch('lifecycle_residuals').zero?
          end
          wait_for_block(name: 'blocked I/O command exits', timeout: 120) do
            !@io_thread.alive?
          end
          io_status, = @io_thread.value
          expect(io_status).not_to eq(0)

          final_info = ct_info(ctid)
          expect(final_info.fetch('runtime_state')).to eq('running')
          expect(final_info.fetch('lifecycle_run_id')).to eq(replacement_run_id)
          expect(final_info.fetch('lifecycle_residuals')).to eq(0)
          machine.succeeds(
            "osctl group set cpu-limit #{group} 100"
          )
          _, restricted_nproc = machine.succeeds(
            "osctl ct exec #{ctid} nproc"
          )
          expect(restricted_nproc.strip.to_i).to eq(1)
          machine.succeeds(
            "osctl group set cpu-limit #{group} 200"
          )
          _, expanded_nproc = machine.succeeds(
            "osctl ct exec #{ctid} nproc"
          )
          expect(expanded_nproc.strip.to_i).to eq(2)
          machine.succeeds(
            "osctl ct cgparams set #{ctid} cpuset.cpus 1"
          )
          _, replacement_mask = machine.succeeds(
            "cat /sys/fs/cgroup/#{replacement_inner}/cpuset.cpus.effective"
          )
          expect(replacement_mask.strip).to eq('1')
          machine.succeeds(
            "test \"$(osctl ct exec #{ctid} cat " \
              "/tmp/lifecycle-generation)\" = replacement-ok"
          )
        end
      end

      describe 'manual legacy-runtime adoption compatibility' do
        ctid = "#{get_container_id}-rollback"
        legacy_pid_file = '/tmp/osctld-lifecycle-legacy.pid'

        before(:context) do
          cleanup_ct(ctid)
          machine.all_succeed(
            "osctl ct new --distribution alpine #{ctid}",
            "osctl ct unset start-menu #{ctid}",
            "osctl ct start #{ctid}",
            "osctl ct stop #{ctid}",
            "osctl ct netif new routed #{ctid} eth0",
            "osctl ct set cpu-limit #{ctid} 250"
          )
        end

        after(:context) do
          machine.execute(<<~SH)
            if test -s #{legacy_pid_file}; then
              pid=$(cat #{legacy_pid_file})
              kill -TERM "$pid" 2>/dev/null || true
              timeout 120 sh -c \
                'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done' \
                sh "$pid" || true
            fi
            rm -f #{legacy_pid_file}
            sv start osctld
          SH
          machine.wait_for_service('osctld')
          machine.wait_for_osctl_pool('tank')
          cleanup_ct(ctid) unless @compat_stop_failed
        end

        it 'adopts a deliberately reconstructed legacy runtime' do
          drained = ct_info(ctid)
          expect(drained.fetch('runtime_state')).to eq('stopped')
          expect(drained.fetch('lifecycle_run_id')).to be_nil
          expect(drained.fetch('lifecycle_residuals')).to eq(0)
          expect(drained.fetch('lifecycle_policy_tainted')).to be(false)
          expect(lifecycle_record(ctid).fetch('active_run_id')).to be_nil
          machine.all_succeed(
            "grep -F 'incarnation_id:' /tank/conf/ct/#{ctid}.yml",
            "test -z \"$(find /tank/conf/group " \
              "-name cgroup-policy.yml -print -quit)\"",
            "test -z \"$(find /sys/fs/cgroup -type d " \
              "-path '*/ct.#{ctid}/runs/*' -print -quit)\""
          )

          _, daemon_config = machine.succeeds(
            "awk '$1 == \"--config\" { print $2; exit }' /service/osctld/run"
          )
          daemon_config = daemon_config.strip
          expect(daemon_config).not_to be_empty
          _, daemon_path = machine.succeeds(<<~'SH')
            pid=$(sv status osctld |
              sed -n 's/.*(pid \([0-9][0-9]*\)).*/\1/p')
            test -n "$pid"
            tr '\0' '\n' <"/proc/$pid/environ" |
              sed -n 's/^PATH=//p'
          SH
          daemon_path = daemon_path.strip
          expect(daemon_path).not_to be_empty

          machine.succeeds('sv -w 120 stop osctld')
          machine.succeeds(
            "rm -f /run/osctl/pools/tank/containers/#{ctid}/lifecycle.yml"
          )
          machine.succeeds(<<~SH)
            nohup env PATH=#{Shellwords.escape(daemon_path)} \
              LANG=en_US.UTF-8 \
              LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive \
              /run/current-system/sw/bin/legacy-osctld \
              --config #{Shellwords.escape(daemon_config)} \
              --log syslog </dev/null \
              >/tmp/osctld-lifecycle-legacy.log 2>&1 &
            printf '%s\n' "$!" >#{legacy_pid_file}
          SH
          begin
            machine.wait_until_succeeds(
              'test -S /run/osctl/osctld.sock && osctl pool show tank >/dev/null',
              timeout: 120
            )
          rescue StandardError => e
            _, legacy_log = machine.execute(
              'cat /tmp/osctld-lifecycle-legacy.log'
            )
            raise "#{e.message}\nlegacy osctld log:\n#{legacy_log}"
          end

          machine.succeeds("osctl ct start --wait infinity #{ctid}")
          machine.wait_for_osctl_container(ctid)
          legacy_running = ct_info(ctid)
          _, legacy_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{ctid}"
          )
          legacy_veth = legacy_veth.strip
          expect(legacy_veth).not_to be_empty
          machine.succeeds("osctl ct freeze #{ctid}")
          machine.wait_until_succeeds(
            "test \"$(osctl ct show -H -o runtime_state #{ctid})\" = frozen",
            timeout: 60
          )
          legacy_frozen = ct_info(ctid)
          expect(legacy_frozen.fetch('init_pid')).to eq(
            legacy_running.fetch('init_pid')
          )

          machine.succeeds(<<~SH)
            pid=$(cat #{legacy_pid_file})
            kill -TERM "$pid"
            timeout 120 sh -c \
              'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done' \
              sh "$pid"
            rm -f #{legacy_pid_file}
            sv start osctld
          SH
          machine.wait_for_service('osctld')
          machine.wait_for_osctl_pool('tank')

          adopted = ct_info(ctid)
          expect(adopted.fetch('runtime_state')).to eq('frozen')
          expect(adopted.fetch('init_pid')).to eq(
            legacy_frozen.fetch('init_pid')
          )
          expect(adopted.fetch('lifecycle_run_id')).not_to be_nil
          adopted_run = lifecycle_run(
            ctid,
            adopted.fetch('lifecycle_run_id')
          )
          expect(adopted_run.fetch('hazards')).to include(
            'adopted legacy runtime'
          )
          adopted_root = adopted_run.fetch('resources').fetch('cgroup_root')
          _, adopted_cpu_max = machine.succeeds(
            <<~SH
              root=#{Shellwords.escape("/sys/fs/cgroup/#{adopted_root}")}
              stable=$(cat "$root/cpu.max")
              finite=$(
                find "$root" -mindepth 2 -type f -name cpu.max \
                  -exec sh -c '
                    for file; do
                      value=$(cat "$file" 2>/dev/null) || continue
                      set -- $value
                      test "$1" = max || printf "%s=%s\n" "$file" "$value"
                    done
                  ' sh {} +
              )
              if test -n "$finite"; then
                printf 'finite descendant CPU policy:\n%s\n' "$finite" >&2
                exit 1
              fi
              printf '%s\n' "$stable"
            SH
          )
          expect(adopted_cpu_max.strip.split.first).to eq('250000')
          _, adopted_veth = machine.succeeds(
            "osctl ct netif ls -H -o veth #{ctid}"
          )
          expect(adopted_veth.strip).to eq(legacy_veth)
          machine.succeeds(
            "test -e /sys/class/net/#{Shellwords.escape(legacy_veth)}"
          )
          machine.succeeds("osctl ct unfreeze #{ctid}")
          machine.wait_until_succeeds(
            "test \"$(osctl ct show -H -o runtime_state #{ctid})\" = running",
            timeout: 60
          )
          machine.succeeds("osctl ct exec #{ctid} true")

          stop_thread = Thread.new do
            machine.execute(
              "osctl ct stop #{ctid}",
              shell: 'io',
              timeout: 300
            )
          end
          begin
            wait_for_block(
              name: 'adopted legacy generation stop',
              timeout: 120
            ) { !stop_thread.alive? }
          rescue StandardError => e
            @compat_stop_failed = true
            _, stop_diagnostics = machine.execute(<<~SH)
              set +e
              osctl -j ct show #{ctid}
              cat /run/osctl/pools/tank/containers/#{ctid}/lifecycle.yml
              ps -eo pid,ppid,stat,comm,args
              tail -n 300 /var/log/osctld
              tail -n 300 /var/log/messages
            SH
            stop_thread.kill
            stop_thread.join
            raise "#{e.message}\nadopted stop diagnostics:\n" \
                  "#{stop_diagnostics}"
          end
          stop_status, stop_output = stop_thread.value
          expect(stop_status).to eq(0), stop_output

          finalized = ct_info(ctid)
          expect(finalized.fetch('runtime_state')).to eq('stopped')
          expect(finalized.fetch('lifecycle_run_id')).to be_nil
          expect(finalized.fetch('lifecycle_residuals')).to eq(0)
        end
      end
    '';
  }
)

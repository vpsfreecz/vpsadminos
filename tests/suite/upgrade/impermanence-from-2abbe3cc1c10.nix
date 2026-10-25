# Baseline: 2abbe3cc1c102a4b39022d3f73ef4a432ad4d616, stable/default,
#   direct userspace switch; the booted kernel and host boot ID remain unchanged.
# Purpose: Preserve impermanent saved/running state across old-writer repair,
#   live run/root/payload continuity, reloads, new-writer persistence and cleanup.
# Target: The checkout being tested, stable/default profile.
# Removal condition: End support for equivalent old saved/running state, including
#   rollback/restoration, or verify replacement real-transition coverage of every
#   guarantee above.
# Retirement evidence: Not established; retain this transition and focused units.
args:
let
  revision = "2abbe3cc1c102a4b39022d3f73ef4a432ad4d616";
  production = builtins.getFlake "github:vpsfreecz/vpsadminos/${revision}";
  candidate = builtins.getFlake (toString ../../..);
  system = args.system or builtins.currentSystem;
in
import (production.outPath + "/tests/make-template.nix")
  (
    { cgroupVersion }:
    assert builtins.elem cgroupVersion [
      1
      2
    ];
    let
      cgroup = {
        boot.enableUnifiedCgroupHierarchy = cgroupVersion == 2;
      };
      target =
        (candidate.lib.vpsadminosSystem {
          inherit system;
          # Explicit stable/default candidate; ignore VPSADMINOS_CONFIG overrides.
          configuration = null;
          modules = [
            ../../configs/vpsadminos/base.nix
            ../../configs/vpsadminos/pool-tank.nix
            cgroup
            ({ lib, ... }: {
              osctl.test-shell.shells = 1;
              system.vpsadminos.enableUnstable = lib.mkForce false;
            })
          ];
        }).config.system.build.toplevel;
    in
    rec {
      instance = "v${toString cgroupVersion}";
      test = { pkgs }: {
        name = "upgrade-impermanence-from-2abbe3cc1c10-${instance}";
        description = "Production ${revision} stable 6.12.113 to candidate impermanent run, cgroup ${instance}";
        tags = [
          "upgrade"
          "ci"
        ];
        attempts = 1;
        machine = import (production.outPath + "/tests/machines/vpsadminos/with-tank.nix") {
          inherit pkgs;
          config = { lib, ... }: {
            imports = [ cgroup ];
            system.vpsadminos.enableUnstable = lib.mkForce false;
            system.extraDependencies = [
              target
              pkgs.ruby
            ];
          };
        };
        testScript = ''
          require 'json'
          require 'shellwords'
          # Sample saved state without invoking the recovery implementation.
          # Hold proc/root/namespace objects throughout each observation.
          impermanence_probe = <<~'RUBY'
            require 'json'
            require 'yaml'
            require 'open3'
            require 'digest'

            def identity(file)
              st = file.stat
              [st.dev, st.ino]
            end

            def saved_file(path)
              fields = ->(st) { [st.dev, st.ino, st.size, st.mtime.to_f, st.ctime.to_f] }
              File.open(path, 'rb') do |file|
                before = fields.call(file.stat)
                path_before = fields.call(File.stat(path))
                raw = file.read(65537) || "".b
                raise "oversized saved state: #{path}" if raw.bytesize > 65536
                after = fields.call(file.stat)
                path_after = fields.call(File.stat(path))
                # Unlink by atomic replacement can change held inode ctime
                # without changing its bytes. Retain that evidence separately.
                raise "saved contents changed during read: #{path}" unless before[0, 4] == after[0, 4]
                { raw: raw, sha256: Digest::SHA256.hexdigest(raw), before: before, after: after,
                  path_before: path_before, path_after: path_after }
              end
            end

            def mount_rows(raw)
              raw.lines.map do |line|
                left, right = line.strip.split(' - ', 2).map(&:split)
                raise 'malformed mountinfo' unless left && right && left.size >= 6 && right.size >= 3
                [left[2], left[3], left[4], right[0], right[1]].map do |field|
                  field.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
                end
              end
            end

            pid, dataset = ARGV
            File.open("/proc/#{Integer(pid)}") do |proc_dir|
              proc_identity = identity(proc_dir)
              held = "/proc/self/fd/#{proc_dir.fileno}"
              File.open("#{held}/root") do |root|
                File.open("#{held}/ns/mnt") do |namespace|
                  before = File.binread("#{held}/stat")
                  status = File.binread("#{held}/status")
                  mounts = File.binread("#{held}/mountinfo")
                  runtime = saved_file('/run/osctl/pools/tank/containers/niximpermanent/config.yml')
                  gc = saved_file('/tank/conf/pool/garbage-collector.yml')
                  cfg = YAML.safe_load(runtime.fetch(:raw))
                  rows = YAML.safe_load(gc.fetch(:raw)).fetch('container_run_datasets')
                  output, error, result = Open3.capture3('zfs', 'list', '-H', '-p', '-t', 'filesystem', '-o', 'name,guid,mountpoint,mounted,origin', dataset)
                  raise "ZFS identity failed: #{error}" unless result.success?
                  zfs = output.lines.map { |line| line.chomp.split("\t", -1) }
                  raise 'ambiguous ZFS identity' unless zfs.one? && zfs.first.size == 5
                  mountpoint = zfs.first.fetch(2)
                  File.open(mountpoint, File::RDONLY | File::NOFOLLOW) do |directory|
                    File.open(File.join(mountpoint, 'private'), File::RDONLY | File::NOFOLLOW) do |private_root|
                      markers = %w[persistent/upgrade-retained upgrade-ephemeral upgrade-writer-ephemeral].to_h do |name|
                        bytes = begin
                          File.binread("#{held}/root/#{name}", 4097) || "".b
                        rescue Errno::ENOENT
                          nil
                        end
                        raise 'oversized marker' if bytes && bytes.bytesize > 4096
                        [name, bytes]
                      end
                      after = File.binread("#{held}/stat")
                      finish_status = File.binread("#{held}/status")
                      stable = identity(proc_dir) == proc_identity &&
                        File.open("#{held}/root") { |file| identity(file) == identity(root) } &&
                        File.open("#{held}/ns/mnt") { |file| identity(file) == identity(namespace) }
                      record = {
                        pid: Integer(pid), proc: proc_identity, root: identity(root), namespace: identity(namespace),
                        stat_before: before, stat_after: after, status_before: status, status_after: finish_status,
                        birth: before.rpartition(') ').last.split.fetch(19),
                        birth_after: after.rpartition(') ').last.split.fetch(19), stable: stable,
                        cgroup: File.binread("#{held}/cgroup"), mountinfo: mounts,
                        root_rows: mount_rows(mounts).select { |row| row[2] == '/' },
                        root_device: "#{root.stat.dev_major}:#{root.stat.dev_minor}",
                        host_rows: mount_rows(File.binread('/proc/self/mountinfo')).select { |row| row[2] == mountpoint },
                        runtime: runtime, gc: gc, config: cfg, gc_rows: rows, zfs: zfs.first,
                        mountpoint: identity(directory), private: identity(private_root), markers: markers
                      }
                      puts JSON.generate(record)
                    end
                  end
                end
              end
            end
          RUBY
          impermanence_sample = lambda do |phase|
            info = machine.osctl_json('ct show niximpermanent')
            command = "timeout -k 2 30 ruby -e #{Shellwords.escape(impermanence_probe)} #{Integer(info.fetch('init_pid'))} #{Shellwords.escape(info.fetch('boot_dataset'))}"
            output = machine.succeeds(command, timeout: 35)[1]
            puts "impermanence #{phase}: #{output}"
            JSON.parse(output).merge('api' => info)
          end
          impermanence_assert = lambda do |record, previous: nil, persisted: false, ephemeral: "inherited-ephemeral\n", writer: nil|
            cfg = record.fetch('config')
            id = cfg.fetch('id')
            expect(id.keys.sort).to eq(%w[container_id pool_name timestamp])
            expect(id.fetch('pool_name')).to eq('tank')
            expect(id.fetch('container_id')).to eq('niximpermanent')
            timestamp = id.fetch('timestamp')
            expect(timestamp.is_a?(Numeric) && timestamp.finite? && timestamp.positive?).to be(true)
            expect(%w[distribution version arch vendor variant].all? { |key| cfg.fetch(key).is_a?(String) && !cfg.fetch(key).empty? }).to be(true)
            info = record.fetch('api')
            expect(info.fetch('impermanence')).to be(true)
            expect(info.fetch('cpu_package_set')).to eq('none')
            expect(info.fetch('cpu_package_inuse')).to be_nil
            expect(cfg.fetch('cpu_package')).to be_nil
            dataset = info.fetch('boot_dataset')
            expect(info.fetch('state')).to eq('running')
            expect(dataset).to match(/\A#{Regexp.escape(info.fetch('dataset'))}\.impermanence-[0-9a-f]{6}\z/)
            owners = record.fetch('gc_rows').select { |row| row.fetch('run_id') == id }
            expect(owners.size).to eq(1)
            expect(owners.first.fetch('dataset')).to eq(dataset)
            overlaps = record.fetch('gc_rows').count do |row|
              other = row.fetch('dataset')
              other == dataset || other.start_with?("#{dataset}/") || dataset.start_with?("#{other}/")
            end
            expect(overlaps).to eq(1)
            record['owner'] = owners.first
            if persisted
              expect(cfg.fetch('dataset')).to eq(dataset)
              expect(cfg.fetch('destroy_dataset_on_stop')).to be(true)
            else
              expect([[info.fetch('dataset'), false], [dataset, true]]).to include([cfg.fetch('dataset'), cfg.fetch('destroy_dataset_on_stop')])
            end
            expect(record.fetch('stable')).to be(true)
            expect(record.fetch('birth_after')).to eq(record.fetch('birth'))
            %w[status_before status_after].each do |key|
              namespace_pids = record.fetch(key).lines.grep(/\ANSpid:/)
              expect(namespace_pids.size).to eq(1)
              ids = namespace_pids.first.split.drop(1)
              expect(ids.size).to be >= 2
              expect(ids.first).to eq(record.fetch('pid').to_s)
              expect(ids.last).to eq('1')
            end
            expect(record.fetch('root_rows')).to eq([[record.fetch('root_device'), '/private', '/', 'zfs', dataset]])
            zfs = record.fetch('zfs')
            expect(zfs[0]).to eq(dataset)
            expect(zfs[1]).to match(/\A[1-9][0-9]*\z/)
            expect(zfs[2]).to start_with('/')
            expect(zfs[3..]).to eq(%w[yes -])
            expect(record.fetch('private')).to eq(record.fetch('root'))
            expect(record.fetch('host_rows')).to eq([[record.fetch('root_device'), '/', zfs[2], 'zfs', dataset]])
            expect(record.fetch('markers')).to eq({
              'persistent/upgrade-retained' => "inherited-persistent\n",
              'upgrade-ephemeral' => ephemeral,
              'upgrade-writer-ephemeral' => writer,
            })
            next unless previous
            expected = previous.fetch('config')
            expected = expected.merge('dataset' => dataset, 'destroy_dataset_on_stop' => true) if persisted
            expect(cfg).to eq(expected)
            # Proc inode identity is held only within each probe. Across independent
            # observations, compare PID/birth and the authenticated root and run.
            %w[pid birth root namespace cgroup root_rows zfs mountpoint private owner].each do |key|
              expect(record.fetch(key)).to eq(previous.fetch(key)), "impermanence #{key} changed across import"
            end
          end

          configure_examples { |config| config.default_order = :defined }
          describe 'current production impermanent run upgraded to candidate userspace' do
            it 'repairs the real stale selection and preserves both production and candidate runs' do
              machine.start
              machine.wait_for_osctl_pool('tank')
              machine.wait_until_online
              expect(machine.succeeds('stat -f -c %T /sys/fs/cgroup')[1].strip).to eq('${
                if cgroupVersion == 2 then "cgroup2fs" else "tmpfs"
              }')
              kernel = machine.succeeds('uname -r')[1].strip
              expect(kernel).to match(/\A6\.12\.113(?:[.-]|$)/)
              boot_id = machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip
              booted = machine.succeeds('readlink -f /run/booted-system')[1].strip
              expect(machine.succeeds('readlink -f /run/current-system')[1].strip).to eq(booted)
              expect(booted).not_to eq('${target}')
              puts "production source=${revision} stable/default kernel=#{kernel}; candidate=${target}; cgroup=v${toString cgroupVersion}"
              unchanged_boot = lambda do
                expect(machine.succeeds('uname -r')[1].strip).to eq(kernel)
                expect(machine.succeeds('cat /proc/sys/kernel/random/boot_id')[1].strip).to eq(boot_id)
                expect(machine.succeeds('readlink -f /run/booted-system')[1].strip).to eq(booted)
                expect(machine.succeeds('readlink -f /run/current-system')[1].strip).to eq('${target}')
              end
              daemon_identity = lambda do
                pids = machine.succeeds("pgrep -f '^osctld: main$'")[1].split
                expect(pids.size).to eq(1)
                stat = machine.succeeds("cat /proc/#{Integer(pids.first)}/stat")[1]
                [pids.first, stat.rpartition(') ').last.split.fetch(19)]
              end
              reload_daemon = lambda do
                prior = daemon_identity.call
                machine.succeeds('sv -w 90 restart osctld', timeout: 120)
                machine.wait_for_service('osctld')
                machine.wait_until_succeeds("pgrep -f '^osctld: main$'")
                machine.wait_for_osctl_pool('tank')
                expect(daemon_identity.call).not_to eq(prior)
                unchanged_boot.call
              end

              # All host configuration setters run while stopped. This public preference
              # bypasses CPU assignment, so no incidental scheduler save masks the writer.
              machine.all_succeed(
                'osctl --pool tank ct new --distribution nixos --version 24.05 --variant impermanence niximpermanent',
                'osctl --pool tank ct unset start-menu niximpermanent',
                'osctl --pool tank ct netif new routed niximpermanent eth0',
                'osctl --pool tank ct netif ip add niximpermanent eth0 192.0.2.32/32',
                'osctl --pool tank ct set dns-resolver niximpermanent 192.0.2.53',
                'osctl --pool tank ct set cpu-package niximpermanent none',
              )
              stopped = machine.osctl_json('ct show niximpermanent')
              expect(stopped.fetch('state')).to eq('stopped')
              expect(stopped.fetch('impermanence')).to be(true)
              expect(stopped.fetch('cpu_package_set')).to eq('none')
              machine.succeeds('osctl --pool tank ct start niximpermanent')
              machine.wait_until_succeeds('osctl ct exec niximpermanent mountpoint -q /persistent', timeout: 120)
              machine.succeeds("osctl ct exec niximpermanent sh -c 'echo inherited-persistent > /persistent/upgrade-retained; echo inherited-ephemeral > /upgrade-ephemeral'")
              legacy = impermanence_sample.call('production writer before switch')
              impermanence_assert.call(legacy)
              cfg = legacy.fetch('config')
              covered = cfg.fetch('dataset') == legacy.fetch('api').fetch('dataset') &&
                cfg.fetch('destroy_dataset_on_stop') == false && cfg.fetch('cpu_package').nil?
              expect(covered).to be(true), 'missing stale-state repair coverage: production writer did not leave BASE/cleanup=false; do not synthesize metadata or retry'

              machine.succeeds('${target}/bin/switch-to-configuration test', timeout: 180)
              machine.wait_for_osctl_pool('tank')
              unchanged_boot.call
              repaired = impermanence_sample.call('candidate import of production run')
              impermanence_assert.call(repaired, previous: legacy, persisted: true)
              reload_daemon.call
              retained = impermanence_sample.call('candidate reload of repaired run')
              impermanence_assert.call(retained, previous: repaired, persisted: true)
              expect(retained.fetch('runtime').fetch('raw')).to eq(repaired.fetch('runtime').fetch('raw'))
              expect(retained.fetch('runtime').fetch('path_after')).to eq(repaired.fetch('runtime').fetch('path_after'))

              machine.succeeds('osctl --pool tank ct restart niximpermanent')
              # Observe final persisted selection before any other setter/readiness action.
              target_run = impermanence_sample.call('immediate candidate writer')
              impermanence_assert.call(target_run, persisted: true, ephemeral: nil)
              expect(target_run.fetch('config').fetch('id')).not_to eq(legacy.fetch('config').fetch('id'))
              expect(target_run.fetch('api').fetch('boot_dataset')).not_to eq(legacy.fetch('api').fetch('boot_dataset'))
              machine.succeeds('osctl ct exec niximpermanent sh -c "echo target-writer-ephemeral > /upgrade-writer-ephemeral"')
              with_payload = impermanence_sample.call('candidate run payload')
              impermanence_assert.call(with_payload, previous: target_run, persisted: true, ephemeral: nil, writer: "target-writer-ephemeral\n")
              expect(with_payload.fetch('runtime').fetch('raw')).to eq(target_run.fetch('runtime').fetch('raw'))
              expect(with_payload.fetch('runtime').fetch('path_after')).to eq(target_run.fetch('runtime').fetch('path_after'))
              reload_daemon.call
              imported = impermanence_sample.call('candidate reload of new run')
              impermanence_assert.call(imported, previous: with_payload, persisted: true, ephemeral: nil, writer: "target-writer-ephemeral\n")
              expect(imported.fetch('runtime').fetch('raw')).to eq(target_run.fetch('runtime').fetch('raw'))
              expect(imported.fetch('runtime').fetch('path_after')).to eq(target_run.fetch('runtime').fetch('path_after'))
              old_root = legacy.fetch('api').fetch('boot_dataset')
              new_root = imported.fetch('api').fetch('boot_dataset')
              machine.wait_until_succeeds("! zfs list -H #{Shellwords.escape(old_root)}", timeout: 120)
              machine.succeeds('osctl --pool tank ct stop niximpermanent')
              machine.wait_until_succeeds("! zfs list -H #{Shellwords.escape(new_root)}", timeout: 120)
              machine.succeeds('osctl --pool tank ct del --prune niximpermanent')
              machine.fails('osctl --pool tank ct show niximpermanent')
            end
          end
        '';
      };
    }
  )
  (
    args
    // {
      # The template/machine implementation and locked inputs are production's.
      # Its stable/default profile must not inherit an unstable CI environment.
      pkgs = production.inputs.nixpkgs.outPath;
      testFramework = production.lib.testFramework;
      configuration = null;
    }
  )

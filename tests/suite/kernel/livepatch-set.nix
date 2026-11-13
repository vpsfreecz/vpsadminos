import ../../make-template.nix (
  { row }:
  let
    planPath = builtins.getEnv "VPSADMINOS_LIVEPATCH_PLAN";
    capturePath = builtins.getEnv "VPSADMINOS_LIVEPATCH_CAPTURE";
    plan = builtins.fromJSON (builtins.readFile planPath);
    capture = builtins.fromJSON (builtins.readFile capturePath);
    sets = builtins.filter (candidate: candidate.id == row.setId) plan.sets;
    set = builtins.head sets;
    capturedSets = builtins.filter (candidate: candidate.id == row.setId) capture.sets;
    capturedSet = builtins.head capturedSets;
  in
  assert planPath != "";
  assert capturePath != "";
  assert builtins.length sets == 1;
  assert builtins.length capturedSets == 1;
  assert row.scope == "set";
  assert row.oracleIds == [ ];
  assert row.oracleShard == "none";
  assert row.validator == "builtin/generic-livepatch-safety-v1";
  {
    instance = row.rowId;

    test =
      { pkgs }:
      let
        workload = import ./livepatch-set/workload.nix { inherit pkgs; };
      in
      {
        name = "kernel-livepatch-set-${row.rowId}";
        description = "Generic livepatch whole-set qualification for ${row.profileId}";
        tags = [ row.runnerClass ];
        labels = {
          livepatch-profile = row.profileId;
          livepatch-set = row.setId;
        };

        machine = import ../../machines/vpsadminos/with-empty.nix {
          inherit pkgs;
          config =
            { lib, ... }:
            {
              imports = [ ../../configs/vpsadminos/livepatch.nix ] ++ workload.modules;
              boot.qemu.cpus = lib.mkOverride 0 8;
              boot.qemu.memory = lib.mkOverride 0 8192;
              environment.systemPackages = [
                pkgs.coreutils
                pkgs.jq
                pkgs.kmod
              ];
            };
        };

        testScript = ''
          require 'json'
          require 'shellwords'

          ROW = ${builtins.toJSON row}
          EXPECTED_SET = ${builtins.toJSON set}
          EXPECTED_CAPTURE = ${builtins.toJSON capturedSet}
          WORKLOAD_DIMENSIONS = %w[
            cpu scheduler forkExec cgroupMigration loopbackNetwork
            filesystemIntegrity
          ].freeze
          KERNEL_FAULT_PATTERN = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|Invalid relocation target|disagrees about version|Unknown symbol|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)/

          def patch_dir(module_name)
            "/sys/kernel/livepatch/#{module_name}"
          end

          def shell(value)
            Shellwords.escape(value)
          end

          def wait_enabled(module_name)
            dir = shell(patch_dir(module_name))
            machine.wait_until_succeeds(
              "test -d #{dir} && test \"$(cat #{dir}/enabled)\" = 1 && " \
                "test \"$(cat #{dir}/transition)\" = 0 && " \
                "test \"$(cat #{dir}/replace)\" = 0",
              timeout: 180,
            )
          end

          def wait_disabled(module_name)
            dir = shell(patch_dir(module_name))
            machine.wait_until_succeeds(
              "test \"$(cat #{dir}/enabled)\" = 0 && " \
                "test \"$(cat #{dir}/transition)\" = 0 && " \
                "test \"$(cat #{dir}/replace)\" = 0",
              timeout: 180,
            )
          end

          def wait_removed(module_name)
            machine.wait_until_succeeds(
              "test ! -d #{shell(patch_dir(module_name))} && " \
                "test ! -d /sys/module/#{shell(module_name)}",
              timeout: 180,
            )
          end

          def validate_capture
            expect(@set).to eq(EXPECTED_SET)
            expect(@captured_set).to eq(EXPECTED_CAPTURE)
            expect(@captured_set.fetch('members').length).to eq(@set.fetch('members').length)
            expect(ROW.fetch('oracleIds')).to eq([])
            expect(ROW.fetch('oracleShard')).to eq('none')
            expect(ROW.fetch('validator')).to eq('builtin/generic-livepatch-safety-v1')

            @captured_set.fetch('members').each_with_index do |member, index|
              expected_member = @set.fetch('members').fetch(index)
              identity = member.fetch('identity')
              producer = shell(identity.fetch('producer'))
              module_path = shell(identity.fetch('module'))
              evidence = "#{producer}/share/vpsadminos-livepatch"
              expect(member.fetch('release')).to eq(expected_member.fetch('release'))
              expect(member.fetch('kernelVersion')).to eq(@set.fetch('kernelVersion'))
              machine.all_succeed(
                "test -f #{module_path}",
                "test \"$(sha256sum #{module_path} | cut -d' ' -f1)\" = #{identity.fetch('moduleSha256')}",
                "test \"$(sha256sum #{evidence}/manifest.json | cut -d' ' -f1)\" = #{identity.fetch('manifestSha256')}",
                "test \"$(sha256sum #{evidence}/inspection.json | cut -d' ' -f1)\" = #{identity.fetch('inspectionSha256')}",
                "test \"$(sha256sum #{evidence}/closure.json | cut -d' ' -f1)\" = #{identity.fetch('closureSha256')}",
                "jq -e '.matches == true and .mismatches == {}' #{evidence}/closure.json",
                "jq -e --arg name #{shell(identity.fetch('moduleName'))} '.module.name == $name and .buildInvocation.nonReplaceRequested == true' #{evidence}/inspection.json",
              )
            end
          end

          def admit_platform
            expected_vendor = {
              'amd' => 'AuthenticAMD',
              'intel' => 'GenuineIntel',
            }.fetch(ROW.fetch('platform').fetch('id'))
            architecture = machine.succeeds('uname -m')[1].strip
            vendors = machine.succeeds(
              "awk -F: '/^vendor_id/{gsub(/[[:space:]]/, \"\", $2); print $2}' /proc/cpuinfo | LC_ALL=C sort -u",
            )[1].lines.map(&:strip).reject(&:empty?)
            hypervisor_flag = machine.succeeds(
              "awk -F: '/^flags/{found=1; if ($2 !~ /(^|[[:space:]])hypervisor([[:space:]]|$)/) missing=1} END{exit (!found || missing)}' /proc/cpuinfo && printf true",
            )[1].strip == 'true'
            lscpu = JSON.parse(machine.succeeds('LC_ALL=C lscpu --json')[1])
            facts = lscpu.fetch('lscpu').to_h do |entry|
              [entry.fetch('field').delete_suffix(':'), entry.fetch('data')]
            end
            hypervisor_vendor = facts.fetch('Hypervisor vendor')

            expect(architecture).to eq('x86_64')
            expect(facts.fetch('Architecture')).to eq('x86_64')
            expect(vendors).to eq([expected_vendor])
            expect(hypervisor_flag).to be(true)
            expect(hypervisor_vendor).to eq('KVM')
            {
              id: ROW.fetch('platform').fetch('id'),
              architecture: architecture,
              cpuVendor: expected_vendor,
              hypervisorFlag: hypervisor_flag,
              hypervisorVendor: hypervisor_vendor,
              admitted: true,
            }
          end

          def workload_snapshot
            value = JSON.parse(machine.succeeds('livepatch-generic-workload snapshot')[1])
            expect(value.keys.sort).to eq(WORKLOAD_DIMENSIONS.sort)
            expect(value.values).to all(be_a(Integer).and(be > 0))
            value
          end

          def workload_progress(baseline)
            value = JSON.parse(
              machine.succeeds(
                "livepatch-generic-workload progress #{shell(JSON.generate(baseline))}",
              )[1],
            )
            WORKLOAD_DIMENSIONS.each do |dimension|
              expect(value.fetch(dimension)).to be > baseline.fetch(dimension)
            end
            value
          end

          def load_set(progress_log = nil)
            observations = []
            @captured_set.fetch('members').each_with_index do |member, index|
              expected_member = @set.fetch('members').fetch(index)
              identity = member.fetch('identity')
              baseline = workload_snapshot unless progress_log.nil?
              machine.succeeds("insmod #{shell(identity.fetch('module'))}", timeout: 60)
              wait_enabled(identity.fetch('moduleName'))
              machine.succeeds("test \"$(uname -r)\" = #{shell(member.fetch('release'))}")
              observations << {
                release: member.fetch('release'),
                enabled: 1,
                transition: 0,
                replace: 0,
              }
              unless progress_log.nil?
                progress_log << {
                  release: member.fetch('release'),
                  before: baseline,
                  after: workload_progress(baseline),
                }
              end
              expect(member.fetch('release')).to eq(expected_member.fetch('release'))
            end
            observations
          end

          def reverse_set(progress_log = nil)
            observations = []
            members = @captured_set.fetch('members')
            members.each_index.to_a.reverse_each do |index|
              member = members.fetch(index)
              identity = member.fetch('identity')
              baseline = workload_snapshot unless progress_log.nil?
              machine.succeeds(
                "sh -c 'echo 0 > #{shell(patch_dir(identity.fetch('moduleName')))}/enabled'",
                timeout: 60,
              )
              wait_disabled(identity.fetch('moduleName'))
              machine.succeeds("rmmod #{shell(identity.fetch('moduleName'))}", timeout: 60)
              wait_removed(identity.fetch('moduleName'))
              expected_release =
                if index.zero?
                  @set.fetch('kernelVersion')
                else
                  members.fetch(index - 1).fetch('release')
                end
              machine.succeeds("test \"$(uname -r)\" = #{shell(expected_release)}")
              observations << {
                removedRelease: member.fetch('release'),
                release: expected_release,
              }
              unless progress_log.nil?
                progress_log << {
                  removedRelease: member.fetch('release'),
                  release: expected_release,
                  before: baseline,
                  after: workload_progress(baseline),
                }
              end
            end
            observations
          end

          def tip_state(member)
            identity = member.fetch('identity')
            dir = shell(patch_dir(identity.fetch('moduleName')))
            module_name = shell(identity.fetch('moduleName'))
            {
              release: machine.succeeds('uname -r')[1].strip,
              enabled: machine.succeeds("cat #{dir}/enabled")[1].strip.to_i,
              transition: machine.succeeds("cat #{dir}/transition")[1].strip.to_i,
              replace: machine.succeeds("cat #{dir}/replace")[1].strip.to_i,
              livepatchInstances: machine.succeeds(
                "find /sys/kernel/livepatch -mindepth 1 -maxdepth 1 -type d -name #{module_name} | wc -l",
              )[1].strip.to_i,
              moduleInstances: machine.succeeds(
                "find /sys/module -mindepth 1 -maxdepth 1 -type d -name #{module_name} | wc -l",
              )[1].strip.to_i,
            }
          end

          before(:suite) do
            machine.start
            machine.wait_until_online
            @plan = JSON.parse(machine.succeeds('cat /etc/livepatch-qualification/plan.json')[1])
            @capture = JSON.parse(machine.succeeds('cat /etc/livepatch-qualification/capture.json')[1])
            @set = @plan.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }.fetch(0)
            @captured_set = @capture.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }.fetch(0)
          end

          describe 'generic catalog-selected livepatch set', order: :defined do
            it 'executes the selected semantic profile' do
              validate_capture
              platform = admit_platform
              expect(machine.succeeds('uname -r')[1].strip).to eq(@set.fetch('kernelVersion'))
              @dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i
              forward = []
              reverse = []
              busy = nil
              failure_recovery = nil
              workload_started = false
              cleanup_complete = false

              begin
                case ROW.fetch('role')
                when 'lifecycle'
                  forward = load_set
                  reverse = reverse_set
                when 'busy-transition'
                  machine.succeeds('livepatch-generic-workload start', timeout: 30)
                  workload_started = true
                  initial = workload_snapshot
                  forward_progress = []
                  reverse_progress = []
                  forward = load_set(forward_progress)
                  reverse = reverse_set(reverse_progress)
                  final = workload_snapshot
                  busy = {
                    dimensions: WORKLOAD_DIMENSIONS,
                    initial: initial,
                    forwardProgress: forward_progress,
                    reverseProgress: reverse_progress,
                    final: final,
                    cleanupComplete: false,
                  }
                when 'failure-recovery'
                  forward = load_set
                  tip = @captured_set.fetch('members').last
                  expected_tip = {
                    release: tip.fetch('release'),
                    enabled: 1,
                    transition: 0,
                    replace: 0,
                    livepatchInstances: 1,
                    moduleInstances: 1,
                  }
                  before = tip_state(tip)
                  expect(before).to eq(expected_tip)
                  machine.fails("insmod #{shell(tip.fetch('identity').fetch('module'))}", timeout: 60)
                  after_duplicate = tip_state(tip)
                  expect(after_duplicate).to eq(before)
                  machine.fails("rmmod #{shell(tip.fetch('identity').fetch('moduleName'))}", timeout: 60)
                  after_removal = tip_state(tip)
                  expect(after_removal).to eq(before)
                  reverse = reverse_set
                  failure_recovery = {
                    duplicateInsertionRefused: true,
                    enabledRemovalRefused: true,
                    tipUnchangedAfterDuplicate: true,
                    tipUnchangedAfterRemoval: true,
                    predecessorRestored: true,
                  }
                else
                  raise "unsupported generic profile role #{ROW.fetch('role')}"
                end
              ensure
                if workload_started
                  cleanup = JSON.parse(
                    machine.succeeds('livepatch-generic-workload cleanup', timeout: 60)[1],
                  )
                  expect(cleanup).to eq('cleanupComplete' => true)
                  cleanup_complete = true
                end
              end

              busy[:cleanupComplete] = cleanup_complete unless busy.nil?
              @captured_set.fetch('members').each do |member|
                module_name = member.fetch('identity').fetch('moduleName')
                machine.fails("test -d #{shell(patch_dir(module_name))}")
                machine.fails("test -d /sys/module/#{shell(module_name)}")
              end
              kernel_output = machine.succeeds("dmesg | tail -n +#{@dmesg_start + 1}")[1]
              fatal_noise_count = kernel_output.scan(KERNEL_FAULT_PATTERN).length
              expect(fatal_noise_count).to eq(0)

              marker = {
                schemaVersion: 1,
                contract: 'generic-livepatch-safety-v1',
                rowId: ROW.fetch('rowId'),
                setId: ROW.fetch('setId'),
                profileId: ROW.fetch('profileId'),
                role: ROW.fetch('role'),
                platform: platform,
                members: @set.fetch('members').map { |member| member.fetch('release') },
                forward: forward,
                reverse: reverse,
                busy: busy,
                failureRecovery: failure_recovery,
                kernelHealth: {
                  clean: true,
                  fatalNoiseCount: fatal_noise_count,
                },
              }
              puts "VPSADMINOS_LIVEPATCH_GENERIC_RESULT #{JSON.generate(marker)}"
            end
          end
        '';
      };
  }
)

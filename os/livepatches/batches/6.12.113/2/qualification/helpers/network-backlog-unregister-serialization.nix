{
  capture,
  oracle,
  plan,
  pkgs,
  qualificationSet,
  row,
  profile ? null,
}:

let
  effectiveProfile =
    if profile == null then
      {
        fixId = "network-backlog-unregister-serialization";
        oracleId = "network-backlog-operation-safety";
        toolName = "network-backlog-operation";
        operationLabel = "veth traffic and interface lifecycle";
        kernelModules = [ ];
        extraPackages = [ ];
        cleanupFixture = ''
          ip netns del lp-backlog >/dev/null 2>&1 || true
          ip link del lpb-host >/dev/null 2>&1 || true
        '';
        setupFixture = ''
          cleanup_fixture
          ip netns add lp-backlog
          ip link add lpb-host type veth peer name lpb-peer
          ip link set lpb-peer netns lp-backlog
          ip addr add 192.0.2.1/30 dev lpb-host
          ip link set lpb-host up
          ip -n lp-backlog link set lo up
          ip -n lp-backlog addr add 192.0.2.2/30 dev lpb-peer
          ip -n lp-backlog link set lpb-peer up
        '';
        oneIteration = ''
          ping -q -c 1 -W 2 192.0.2.2 >/dev/null
          ip netns exec lp-backlog ping -q -c 1 -W 2 192.0.2.1 >/dev/null
          ip -n lp-backlog link set lpb-peer down
          ip -n lp-backlog link set lpb-peer up
          ip netns exec lp-backlog ping -q -c 1 -W 2 192.0.2.1 >/dev/null
        '';
      }
    else
      profile;

  inherit (effectiveProfile)
    cleanupFixture
    extraPackages
    fixId
    kernelModules
    oneIteration
    operationLabel
    oracleId
    setupFixture
    toolName
    ;

  operationTool = pkgs.writeShellScriptBin toolName ''
    set -euo pipefail

    state_dir=/run/${fixId}-operation

    fail() {
      echo "${toolName}: $*" >&2
      exit 1
    }

    write_count() {
      value=$1
      tmp="$state_dir/count.$$"
      printf '%s\n' "$value" > "$tmp"
      chmod 0600 "$tmp"
      mv -T "$tmp" "$state_dir/count"
    }

    write_status() {
      status=$1
      operations=$2
      tmp="$state_dir/status.$$"
      printf 'status=%s\noperations=%s\n' "$status" "$operations" > "$tmp"
      chmod 0600 "$tmp"
      mv -T "$tmp" "$state_dir/status"
    }

    cleanup_fixture() {
      ${cleanupFixture}
    }

    setup_fixture() {
      ${setupFixture}
    }

    one_iteration() {
      ${oneIteration}
    }

    command=''${1-}
    case "$command" in
      prepare)
        test ! -e "$state_dir/pid" || fail "workload pid already exists"
        install -d -m 0700 "$state_dir"
        rm -f "$state_dir/stop" "$state_dir/status" "$state_dir/count"
        setup_fixture
        write_count 0
        ;;

      start)
        test -f "$state_dir/count" || fail "fixture is not prepared"
        test ! -e "$state_dir/pid" || fail "workload pid already exists"
        nohup "$0" worker > "$state_dir/workload.log" 2>&1 < /dev/null &
        pid=$!
        printf '%s\n' "$pid" > "$state_dir/pid"
        kill -0 "$pid"
        ;;

      worker)
        operations=$(cat "$state_dir/count")
        while test ! -e "$state_dir/stop"; do
          one_iteration
          operations=$((operations + 1))
          write_count "$operations"
          if test "$operations" -ge 20000; then
            write_status exhausted "$operations"
            exit 1
          fi
        done
        write_status ok "$operations"
        ;;

      progress)
        previous=''${2--1}
        [[ "$previous" =~ ^-?[0-9]+$ ]] || fail "invalid previous operation count"
        for _ in $(seq 1 240); do
          current=$(cat "$state_dir/count")
          [[ "$current" =~ ^[0-9]+$ ]] || fail "invalid operation count"
          if test "$current" -gt "$previous"; then
            printf 'operations=%s\n' "$current"
            exit 0
          fi
          sleep 0.25
        done
        fail "ordinary operation did not make progress"
        ;;

      stop)
        pid=$(cat "$state_dir/pid")
        [[ "$pid" =~ ^[0-9]+$ ]] || fail "invalid workload pid"
        kill -0 "$pid" || fail "workload is not running"
        : > "$state_dir/stop"
        timeout 60 tail --pid="$pid" -f /dev/null
        ! kill -0 "$pid" 2>/dev/null || fail "workload did not stop"
        test -f "$state_dir/status" || fail "workload status is missing"
        grep -Fx 'status=ok' "$state_dir/status" >/dev/null
        cat "$state_dir/status"
        ;;

      cleanup)
        if test -f "$state_dir/pid"; then
          pid=$(cat "$state_dir/pid")
          ! kill -0 "$pid" 2>/dev/null || fail "workload is still running"
        fi
        cleanup_fixture
        rm -f "$state_dir/pid" "$state_dir/stop" "$state_dir/status" \
          "$state_dir/count" "$state_dir/workload.log"
        rmdir "$state_dir"
        ;;

      *)
        fail "unsupported command: $command"
        ;;
    esac
  '';

  expectedSetJson = builtins.toJSON qualificationSet;
  oracleScript = ''
    require 'json'
    require 'shellwords'

    def validate_network_capture_relation(plan_set, captured_set)
      planned_members = plan_set.fetch('members')
      captured_members = captured_set.fetch('members')
      raise 'planned member set does not include release 6.12.113.2' if planned_members.length < 2
      raise 'capture member count does not match plan' unless captured_members.length == planned_members.length
      raise 'planned set does not start at 6.12.113.1' unless planned_members.first.fetch('release') == '6.12.113.1'
      raise 'planned set does not contain release 6.12.113.2' unless planned_members.fetch(1).fetch('release') == '6.12.113.2'
      raise 'planned set ID does not match its tip' unless plan_set.fetch('id') == planned_members.last.fetch('release')
      raise 'planned tip release does not match its members' unless
        plan_set.fetch('tipRelease') == planned_members.last.fetch('release')

      captured_members.each_with_index do |member, index|
        planned_member = planned_members.fetch(index)
        expected_release = "6.12.113.#{index + 1}"
        expected_predecessor = index.zero? ? nil : planned_members.fetch(index - 1).fetch('release')
        raise 'planned member release is not contiguous' unless planned_member.fetch('release') == expected_release
        raise 'planned member ordinal is not contiguous' unless planned_member.fetch('releaseOrdinal') == index + 1
        raise 'planned member predecessor is inconsistent' unless
          planned_member.fetch('predecessorRelease') == expected_predecessor
        raise 'planned member target does not match set target' unless
          planned_member.fetch('kernelVersion') == plan_set.fetch('kernelVersion')
        raise 'capture member release does not match plan' unless
          member.fetch('release') == planned_member.fetch('release')
      end
    end

    expected_set = JSON.parse(${builtins.toJSON expectedSetJson})
    plan_sets = @plan.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }
    captured_sets = @capture.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }
    expect(plan_sets.length).to eq(1)
    expect(captured_sets.length).to eq(1)
    plan_set = plan_sets.fetch(0)
    captured_set = captured_sets.fetch(0)
    expect(plan_set).to eq(expected_set)
    validate_network_capture_relation(plan_set, captured_set)
    planned_members = plan_set.fetch('members')
    captured_members = captured_set.fetch('members')
    expect(captured_members.map { |member| member.fetch('release') }).to eq(
      planned_members.map { |member| member.fetch('release') },
    )
    captured_members.each_with_index do |member, index|
      expect(member.fetch('release')).to eq(planned_members.fetch(index).fetch('release'))
      expect(planned_members.fetch(index).fetch('kernelVersion')).to eq(plan_set.fetch('kernelVersion'))
    end
    expect(plan_set.fetch('kernelVersion')).to eq('6.12.113')
    expect(ROW.fetch('scope')).to eq('fix')
    expect(ROW.fetch('role')).to eq('operation-safety')
    expect(ROW.fetch('oracleIds')).to eq([${builtins.toJSON oracleId}])
    expect(ROW.fetch('supported')).to eq(true)
    expect(ROW.fetch('platform').fetch('id')).to eq(ROW.fetch('platformId'))
    expect(ROW.fetch('platform').fetch('runnerClass')).to eq(ROW.fetch('runnerClass'))

    expected_vendor = {
      'amd' => 'AuthenticAMD',
      'intel' => 'GenuineIntel',
    }.fetch(ROW.fetch('platformId'))
    vendor = machine.succeeds("awk -F: '/vendor_id/{gsub(/ /, \"\", $2); print $2; exit}' /proc/cpuinfo")[1].strip
    expect(vendor).to eq(expected_vendor)

    required_identity = %w[
      closureSha256 flakeLockSha256 inputDigest inspectionSha256 manifestSha256
      module moduleName moduleSha256 producer sourceRevision targetId vermagic
    ]
    captured_members.each do |member|
      identity = member.fetch('identity')
      expect(identity.keys.sort).to eq(required_identity.sort)
      producer = Shellwords.escape(identity.fetch('producer'))
      module_path = Shellwords.escape(identity.fetch('module'))
      module_name = Shellwords.escape(identity.fetch('moduleName'))
      evidence = "#{producer}/share/vpsadminos-livepatch"
      machine.all_succeed(
        "test -f #{module_path}",
        "test \"$(sha256sum #{module_path} | cut -d' ' -f1)\" = #{identity.fetch('moduleSha256')}",
        "test \"$(sha256sum #{evidence}/manifest.json | cut -d' ' -f1)\" = #{identity.fetch('manifestSha256')}",
        "test \"$(sha256sum #{evidence}/inspection.json | cut -d' ' -f1)\" = #{identity.fetch('inspectionSha256')}",
        "test \"$(sha256sum #{evidence}/closure.json | cut -d' ' -f1)\" = #{identity.fetch('closureSha256')}",
        "jq -e '.matches == true and .mismatches == {}' #{evidence}/closure.json",
        "jq -e --arg name #{module_name} '.module.name == $name and .buildInvocation.nonReplaceRequested == true' #{evidence}/inspection.json",
      )
    end

    enable_member = lambda do |member|
      identity = member.fetch('identity')
      module_path = Shellwords.escape(identity.fetch('module'))
      module_name = identity.fetch('moduleName')
      module_name_shell = Shellwords.escape(module_name)
      patch_dir = "/sys/kernel/livepatch/#{module_name}"
      machine.succeeds("test ! -e #{Shellwords.escape(patch_dir)} && test ! -e /sys/module/#{module_name_shell}")
      machine.succeeds("insmod #{module_path}", timeout: 60)
      machine.wait_until_succeeds(
        "test -d #{Shellwords.escape(patch_dir)} && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/enabled)\" = 1 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/transition)\" = 0 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/replace)\" = 0",
        timeout: 180,
      )
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(member.fetch('release'))}")
      {
        release: member.fetch('release'),
        enabled: 1,
        transition: 0,
        replace: 0,
      }
    end

    disable_member = lambda do |member, expected_release|
      identity = member.fetch('identity')
      module_name = identity.fetch('moduleName')
      module_name_shell = Shellwords.escape(module_name)
      patch_dir = "/sys/kernel/livepatch/#{module_name}"
      machine.succeeds("sh -c 'echo 0 > #{Shellwords.escape(patch_dir)}/enabled'", timeout: 60)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && test -d /sys/module/#{module_name_shell}",
        timeout: 180,
      )
      machine.succeeds("rmmod #{module_name_shell}", timeout: 60)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && test ! -d /sys/module/#{module_name_shell}",
        timeout: 180,
      )
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(expected_release)}")
      {
        removedRelease: member.fetch('release'),
        release: expected_release,
        moduleRemoved: true,
      }
    end

    progress = lambda do |previous|
      output = machine.succeeds("${toolName} progress #{previous}")[1]
      match = output.match(/^operations=([0-9]+)$/)
      expect(match).not_to be_nil
      Integer(match[1], 10)
    end

    machine.succeeds('test "$(uname -r)" = 6.12.113')
    dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i
    machine.succeeds('${toolName} prepare')
    machine.succeeds('${toolName} start')
    checkpoints = [progress.call(-1)]

    forward = captured_members.map do |member|
      boundary = enable_member.call(member)
      checkpoints << progress.call(checkpoints.last)
      boundary
    end

    reverse = captured_members.each_index.reverse_each.map do |index|
      predecessor_release = index.zero? ? '6.12.113' : captured_members.fetch(index - 1).fetch('release')
      boundary = disable_member.call(captured_members.fetch(index), predecessor_release)
      checkpoints << progress.call(checkpoints.last)
      boundary
    end

    workload = machine.succeeds('${toolName} stop')[1]
    operations_match = workload.match(/^operations=([0-9]+)$/)
    expect(operations_match).not_to be_nil
    operations = Integer(operations_match[1], 10)
    expect(operations).to be >= checkpoints.last
    machine.succeeds('${toolName} cleanup')

    kernel_output = machine.succeeds("dmesg | tail -n +#{dmesg_start + 1}")[1]
    fatal_pattern = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)|KASAN:|KFENCE:/
    expect(kernel_output).not_to match(fatal_pattern)

    marker = {
      schemaVersion: 1,
      oracleId: ${builtins.toJSON oracleId},
      platformId: ROW.fetch('platformId'),
      runnerClass: ROW.fetch('runnerClass'),
      rowId: ROW.fetch('rowId'),
      setId: ROW.fetch('setId'),
      release: plan_set.fetch('tipRelease'),
      nativeRelease: '6.12.113',
      memberReleases: captured_members.map { |member| member.fetch('release') },
      identities: captured_members.map { |member| member.fetch('identity') },
      workload: {
        operations: operations,
        checkpoints: checkpoints,
        ordinaryOperation: ${builtins.toJSON operationLabel},
      },
      forward: {
        orderedReleases: captured_members.map { |member| member.fetch('release') },
        replace: 0,
        boundaries: forward,
      },
      reverse: {
        orderedReleases: reverse.map { |boundary| boundary.fetch(:release) },
        modulesRemoved: true,
        boundaries: reverse,
      },
      kernelHealth: 'clean',
    }
    puts "VPSADMINOS_LIVEPATCH_ORACLE_RESULT #{JSON.generate(marker)}"
  '';
in
{
  modules = [
    (
      { ... }:
      {
        boot.kernelModules = kernelModules;
        environment.systemPackages = [
          operationTool
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.iproute2
          pkgs.iputils
          pkgs.jq
          pkgs.kmod
          pkgs.nftables
          pkgs.python3
          pkgs.util-linux
        ]
        ++ extraPackages;
      }
    )
  ];

  prepareScript = "";
  busyScript = "";
  heldScript = "";
  failureScript = "";
  fixedScript = "";
  recoveryScript = "";

  oracleScripts.operation-safety = oracleScript;
}

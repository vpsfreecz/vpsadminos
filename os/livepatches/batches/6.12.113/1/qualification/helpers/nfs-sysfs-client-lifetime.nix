{
  capture,
  oracle,
  plan,
  pkgs,
  qualificationSet,
  row,
}:

let
  operationTool = pkgs.writeShellScriptBin "nfs-livepatch-operation" ''
    set -euo pipefail

    state_dir=/run/nfs-livepatch-operation
    mount_a=/mnt/nfs-livepatch-a
    mount_b=/mnt/nfs-livepatch-b
    mount_fresh=/mnt/nfs-livepatch-fresh
    seed=livepatch-nfs-integrity-v1

    fail() {
      echo "nfs-livepatch-operation: $*" >&2
      exit 1
    }

    require_mounted() {
      mountpoint -q "$mount_a" || fail "$mount_a is not mounted"
      mountpoint -q "$mount_b" || fail "$mount_b is not mounted"
    }

    write_status() {
      status=$1
      operations=$2
      checksum=$3
      tmp="$state_dir/status.$$"
      printf 'status=%s\noperations=%s\nchecksum=%s\n' \
        "$status" "$operations" "$checksum" > "$tmp"
      chmod 0600 "$tmp"
      mv -T "$tmp" "$state_dir/status"
    }

    command=''${1-}
    case "$command" in
      prepare)
        install -d -m 0700 "$state_dir"
        install -d -m 0755 "$mount_a" "$mount_b" "$mount_fresh"
        ! mountpoint -q "$mount_a" || fail "$mount_a is already mounted"
        ! mountpoint -q "$mount_b" || fail "$mount_b is already mounted"
        mount -t nfs -o vers=4.2,proto=tcp 127.0.0.1:/ "$mount_a"
        mount -t nfs -o vers=4.2,proto=tcp 127.0.0.1:/ "$mount_b"
        printf '%s\n' "$seed" > "$mount_a/seed.tmp"
        dd if="$mount_a/seed.tmp" of="$mount_a/seed" conv=fsync status=none
        rm -f "$mount_a/seed.tmp"
        expected=$(printf '%s\n' "$seed" | sha256sum | cut -d' ' -f1)
        actual=$(sha256sum "$mount_b/seed" | cut -d' ' -f1)
        test "$actual" = "$expected" || fail "initial checksum mismatch"
        stat "$mount_a/seed" "$mount_b/seed" >/dev/null
        printf 'checksum=%s\n' "$expected"
        ;;

      start)
        require_mounted
        test ! -e "$state_dir/pid" || fail "workload pid already exists"
        test ! -e "$state_dir/status" || fail "workload status already exists"
        test ! -e "$state_dir/stop" || fail "workload stop already exists"
        nohup "$0" worker > "$state_dir/workload.log" 2>&1 < /dev/null &
        pid=$!
        printf '%s\n' "$pid" > "$state_dir/pid"
        kill -0 "$pid"
        ;;

      worker)
        require_mounted
        operations=0
        while test ! -e "$state_dir/stop"; do
          printf 'a-%08d\n' "$operations" > "$mount_a/io-a.tmp"
          dd if="$mount_a/io-a.tmp" of="$mount_a/io-a" conv=fsync status=none
          rm -f "$mount_a/io-a.tmp"
          printf 'b-%08d\n' "$operations" > "$mount_b/io-b.tmp"
          dd if="$mount_b/io-b.tmp" of="$mount_b/io-b" conv=fsync status=none
          rm -f "$mount_b/io-b.tmp"
          cmp -s "$mount_a/seed" "$mount_b/seed"
          stat "$mount_a/io-a" "$mount_b/io-b" >/dev/null
          operations=$((operations + 1))
          if test "$operations" -ge 20000; then
            write_status exhausted "$operations" -
            exit 1
          fi
        done
        checksum=$(sha256sum "$mount_b/seed" | cut -d' ' -f1)
        write_status ok "$operations" "$checksum"
        ;;

      operate)
        require_mounted
        expected=$(printf '%s\n' "$seed" | sha256sum | cut -d' ' -f1)
        for mountpoint_path in "$mount_a" "$mount_b"; do
          actual=$(sha256sum "$mountpoint_path/seed" | cut -d' ' -f1)
          test "$actual" = "$expected" || fail "checksum mismatch on $mountpoint_path"
          printf 'serial-operation\n' > "$mountpoint_path/serial.tmp"
          dd if="$mountpoint_path/serial.tmp" of="$mountpoint_path/serial" conv=fsync status=none
          mv "$mountpoint_path/serial" "$mountpoint_path/serial-renamed"
          stat "$mountpoint_path/serial-renamed" >/dev/null
        done
        ;;

      fresh)
        phase=''${2-}
        test -n "$phase" || fail "fresh mount phase is missing"
        ! mountpoint -q "$mount_fresh" || fail "$mount_fresh is already mounted"
        mount -t nfs -o vers=4.2,proto=tcp 127.0.0.1:/ "$mount_fresh"
        expected=$(printf '%s\n' "$seed" | sha256sum | cut -d' ' -f1)
        actual=$(sha256sum "$mount_fresh/seed" | cut -d' ' -f1)
        test "$actual" = "$expected" || fail "fresh mount checksum mismatch"
        printf '%s\n' "$phase" > "$mount_fresh/$phase.tmp"
        dd if="$mount_fresh/$phase.tmp" of="$mount_fresh/$phase" conv=fsync status=none
        rm -f "$mount_fresh/$phase.tmp"
        stat "$mount_fresh/$phase" >/dev/null
        umount "$mount_fresh"
        ;;

      stop)
        require_mounted
        pid=$(cat "$state_dir/pid")
        [[ "$pid" =~ ^[0-9]+$ ]] || fail "invalid workload pid"
        kill -0 "$pid" || fail "workload is not running"
        : > "$state_dir/stop"
        timeout 30 tail --pid="$pid" -f /dev/null
        ! kill -0 "$pid" 2>/dev/null || fail "workload did not stop"
        test -f "$state_dir/status" || fail "workload status is missing"
        grep -Fx 'status=ok' "$state_dir/status" >/dev/null
        cat "$state_dir/status"
        ;;

      cleanup)
        pid=$(cat "$state_dir/pid")
        ! kill -0 "$pid" 2>/dev/null || fail "workload is still running"
        ! mountpoint -q "$mount_fresh" || fail "fresh mount is still active"
        umount "$mount_b"
        umount "$mount_a"
        ! mountpoint -q "$mount_a" || fail "$mount_a remained mounted"
        ! mountpoint -q "$mount_b" || fail "$mount_b remained mounted"
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

    # F6_NFS_CAPTURE_RELATION_BEGIN
    def validate_nfs_capture_relation(plan_set, captured_set)
      planned_members = plan_set.fetch('members')
      captured_members = captured_set.fetch('members')
      raise 'planned member set is empty' if planned_members.empty?
      raise 'capture member count does not match plan' unless captured_members.length == planned_members.length
      raise 'planned set does not start at 6.12.113.1' unless planned_members.first.fetch('release') == '6.12.113.1'
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
        raise 'capture member release does not match plan' unless member.fetch('release') == planned_member.fetch('release')
        raise 'planned member target does not match set target' unless planned_member.fetch('kernelVersion') == plan_set.fetch('kernelVersion')
      end
    end
    # F6_NFS_CAPTURE_RELATION_END

    expected_set = JSON.parse(${builtins.toJSON expectedSetJson})
    plan_sets = @plan.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }
    captured_sets = @capture.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }
    expect(plan_sets.length).to eq(1)
    expect(captured_sets.length).to eq(1)
    plan_set = plan_sets.fetch(0)
    captured_set = captured_sets.fetch(0)
    expect(plan_set).to eq(expected_set)
    validate_nfs_capture_relation(plan_set, captured_set)
    expect(@plan.fetch('counts').fetch('catalogReleases')).to eq(@plan.fetch('releases').length)
    expect(@plan.fetch('counts').fetch('normalizedReleases')).to eq(@plan.fetch('releases').length)
    expect(@plan.fetch('counts').fetch('plannedMembers')).to eq(plan_set.fetch('members').length)
    expect(@plan.fetch('counts').fetch('activeOracles')).to eq(plan_set.fetch('oracleIds').length)
    expect(@plan.fetch('counts').fetch('coverageTuples')).to eq(@plan.fetch('coverage').length)
    expect(@plan.fetch('counts').fetch('plannedRows')).to eq(@plan.fetch('rows').length)
    expect(@plan.fetch('counts').fetch('matrixRows')).to eq(@plan.fetch('matrix').fetch('include').length)
    expect(ROW.fetch('scope')).to eq('fix')
    expect(ROW.fetch('role')).to eq('operation-safety')
    expect(ROW.fetch('oracleIds')).to eq(['nfs-client-operation-safety'])
    expect(ROW.fetch('platform').fetch('id')).to eq(ROW.fetch('platformId'))
    expect(ROW.fetch('platform').fetch('runnerClass')).to eq(ROW.fetch('runnerClass'))
    expect(ROW.fetch('supported')).to eq(true)

    expected_vendor = {
      'amd' => 'AuthenticAMD',
      'intel' => 'GenuineIntel',
    }.fetch(ROW.fetch('platformId'))

    # F9_NFS_COMPLETED_DISABLE_BEGIN
    def wait_nfs_completed_disable(machine, patch_dir, module_name)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && " \
          "test -d /sys/module/#{Shellwords.escape(module_name)}",
        timeout: 180,
      )
    end
    # F9_NFS_COMPLETED_DISABLE_END

    # D7_NFS_STACK_LIFECYCLE_BEGIN
    def load_nfs_set(machine, members)
      members.map do |member|
        machine.succeeds("insmod #{member.fetch(:module_path)}", timeout: 60)
        patch_dir = member.fetch(:patch_dir)
        machine.wait_until_succeeds(
          "test -d #{Shellwords.escape(patch_dir)} && " \
            "test \"$(cat #{Shellwords.escape(patch_dir)}/enabled)\" = 1 && " \
            "test \"$(cat #{Shellwords.escape(patch_dir)}/transition)\" = 0 && " \
            "test \"$(cat #{Shellwords.escape(patch_dir)}/replace)\" = 0",
          timeout: 180,
        )
        machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(member.fetch(:release))}")
        {
          release: member.fetch(:release),
          enabled: 1,
          transition: 0,
          replace: 0,
        }
      end
    end

    def reverse_nfs_set(machine, members, native_release)
      members.each_index.reverse_each.map do |index|
        member = members.fetch(index)
        predecessor_release = index.zero? ? native_release : members.fetch(index - 1).fetch(:release)
        patch_dir = member.fetch(:patch_dir)
        module_name = member.fetch(:module_name)
        module_name_shell = Shellwords.escape(module_name)

        # F9_NFS_REVERSE_BOUNDARY_BEGIN
        machine.succeeds("sh -c 'echo 0 > #{Shellwords.escape(patch_dir)}/enabled'", timeout: 60)
        wait_nfs_completed_disable(machine, patch_dir, module_name)
        machine.succeeds("rmmod #{module_name_shell}", timeout: 60)
        machine.wait_until_succeeds(
          "test ! -d #{Shellwords.escape(patch_dir)} && test ! -d /sys/module/#{module_name_shell}",
          timeout: 180,
        )
        machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(predecessor_release)}")
        # F9_NFS_REVERSE_BOUNDARY_END
        {
          removedRelease: member.fetch(:release),
          release: predecessor_release,
          moduleRemoved: true,
        }
      end
    end
    # D7_NFS_STACK_LIFECYCLE_END

    vendor = machine.succeeds("awk -F: '/vendor_id/{gsub(/ /, \"\", $2); print $2; exit}' /proc/cpuinfo")[1].strip
    expect(vendor).to eq(expected_vendor)

    expect(plan_set.fetch('kernelVersion')).to eq('6.12.113')
    captured_members = captured_set.fetch('members')
    member_records = captured_members.map do |member|
      identity = member.fetch('identity')
      expect(identity.keys.sort).to eq(%w[
        closureSha256 flakeLockSha256 inputDigest inspectionSha256 manifestSha256
        module moduleName moduleSha256 producer sourceRevision targetId vermagic
      ].sort)
      {
        release: member.fetch('release'),
        identity: identity,
        module_path: Shellwords.escape(identity.fetch('module')),
        module_name: identity.fetch('moduleName'),
        patch_dir: "/sys/kernel/livepatch/#{identity.fetch('moduleName')}",
      }
    end

    machine.all_succeed(
      "test \"$(uname -r)\" = 6.12.113",
      "sv check nfsd",
    )
    member_records.each do |member|
      identity = member.fetch(:identity)
      producer = Shellwords.escape(identity.fetch('producer'))
      evidence = "#{producer}/share/vpsadminos-livepatch"
      module_path = member.fetch(:module_path)
      module_name_shell = Shellwords.escape(member.fetch(:module_name))
      machine.all_succeed(
        "test -f #{module_path}",
        "test \"$(sha256sum #{module_path} | cut -d' ' -f1)\" = #{identity.fetch('moduleSha256')}",
        "test \"$(sha256sum #{evidence}/manifest.json | cut -d' ' -f1)\" = #{identity.fetch('manifestSha256')}",
        "test \"$(sha256sum #{evidence}/inspection.json | cut -d' ' -f1)\" = #{identity.fetch('inspectionSha256')}",
        "test \"$(sha256sum #{evidence}/closure.json | cut -d' ' -f1)\" = #{identity.fetch('closureSha256')}",
        "jq -e '.matches == true and .mismatches == {}' #{evidence}/closure.json",
        "jq -e --arg name #{module_name_shell} '.module.name == $name and .buildInvocation.nonReplaceRequested == true' #{evidence}/inspection.json",
        "test ! -e #{Shellwords.escape(member.fetch(:patch_dir))}",
      )
    end

    dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i
    prepare = machine.succeeds('nfs-livepatch-operation prepare')[1]
    integrity_match = prepare.match(/^checksum=([0-9a-f]{64})$/)
    expect(integrity_match).not_to be_nil
    integrity_sha256 = integrity_match[1]
    machine.succeeds('nfs-livepatch-operation start')

    forward = load_nfs_set(machine, member_records)
    machine.succeeds('nfs-livepatch-operation operate')
    machine.succeeds('nfs-livepatch-operation fresh after-forward')

    reverse = reverse_nfs_set(machine, member_records, '6.12.113')
    machine.succeeds('nfs-livepatch-operation operate')
    machine.succeeds('nfs-livepatch-operation fresh after-reverse')

    workload = machine.succeeds('nfs-livepatch-operation stop')[1]
    operations_match = workload.match(/^operations=([0-9]+)$/)
    workload_match = workload.match(/^checksum=([0-9a-f]{64})$/)
    expect(operations_match).not_to be_nil
    expect(workload_match).not_to be_nil
    operations = Integer(operations_match[1], 10)
    workload_sha256 = workload_match[1]
    expect(operations).to be > 0
    expect(workload_sha256).to eq(integrity_sha256)
    machine.succeeds('nfs-livepatch-operation cleanup')

    kernel_output = machine.succeeds("dmesg | tail -n +#{dmesg_start + 1}")[1]
    fatal_pattern = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)|NFS:.*(?:fatal|error)|RPC:.*(?:fatal|error)/
    expect(kernel_output).not_to match(fatal_pattern)

    marker = {
      schemaVersion: 1,
      oracleId: 'nfs-client-operation-safety',
      platformId: ROW.fetch('platformId'),
      runnerClass: ROW.fetch('runnerClass'),
      rowId: ROW.fetch('rowId'),
      setId: ROW.fetch('setId'),
      nativeRelease: '6.12.113',
      tipRelease: plan_set.fetch('tipRelease'),
      members: captured_members.map { |member|
        {
          release: member.fetch('release'),
          identity: member.fetch('identity'),
        }
      },
      workload: {
        mounts: 2,
        freshMounts: 2,
        operations: operations,
        integritySha256: integrity_sha256,
      },
      quiescence: {
        mountCreation: true,
        finalUnmount: true,
        shutdownSysfsWrites: true,
      },
      forward: forward,
      reverse: reverse,
      kernelHealth: 'clean',
    }
    puts "VPSADMINOS_LIVEPATCH_ORACLE_RESULT #{JSON.generate(marker)}"
  '';
in
{
  modules = [
    (
      { pkgs, ... }:
      {
        system.activationScripts.nfsLivepatchQualification = ''
          ${pkgs.coreutils}/bin/install -d -m 0755 /srv/nfs-livepatch
        '';
        services.nfs.server = {
          enable = true;
          nfsd.allowedVersions = [ "4.2" ];
          exports = ''
            /srv/nfs-livepatch 127.0.0.1(rw,sync,no_subtree_check,no_root_squash,insecure,fsid=0)
          '';
        };
        environment.systemPackages = [
          operationTool
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.nfs-utils
          pkgs.util-linux
        ];
      }
    )
  ];

  # Generic set profiles test generic livepatch mechanics only. The real NFS
  # operation adapter is selected exclusively by the two fix-oracle rows.
  prepareScript = "";
  busyScript = "";
  heldScript = "";
  failureScript = "";
  fixedScript = "";
  recoveryScript = "";

  oracleScripts.operation-safety = oracleScript;
}

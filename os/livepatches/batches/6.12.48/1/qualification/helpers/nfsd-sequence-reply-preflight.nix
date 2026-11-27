{
  capture,
  oracle,
  plan,
  pkgs,
  qualificationSet,
  row,
}:

let
  operationTool = pkgs.writeShellScriptBin "nfsd-sequence-operation" ''
    set -euo pipefail
    state=/run/nfsd-sequence-operation
    mount_main=/mnt/nfsd-sequence-main
    mount_fresh=/mnt/nfsd-sequence-fresh
    seed=nfsd-sequence-operation-integrity-v1

    fail() {
      echo "nfsd-sequence-operation: $*" >&2
      exit 1
    }

    mounted() {
      mountpoint -q "$mount_main" || fail "persistent mount is missing"
      test "$(findmnt -rn -o ID --mountpoint "$mount_main")" = "$(cat "$state/mount-id")" \
        || fail "persistent mount was replaced"
      findmnt -rn -o OPTIONS --mountpoint "$mount_main" | tr ',' '\n' | grep -Fx 'vers=4.1' >/dev/null
      test "$(cat /proc/fs/nfsd/threads)" -gt 0 || fail "nfsd is not running"
    }

    integrity() {
      expected=$(printf '%s\n' "$seed" | sha256sum | cut -d' ' -f1)
      actual=$(sha256sum "$mount_main/seed" | cut -d' ' -f1)
      test "$actual" = "$expected" || fail "persistent file checksum mismatch"
    }

    status() {
      printf 'status=%s\noperations=%s\nchecksum=%s\n' "$1" "$2" "$3" > "$state/status.$$"
      mv -T "$state/status.$$" "$state/status"
    }

    monotonic_seconds() {
      awk '{ print int($1) }' /proc/uptime
    }

    nfsd_timer() {
      if test -r "$1"; then
        tr -d '\n' < "$1"
      else
        printf 'unavailable'
      fi
    }

    readiness_snapshot() {
      readiness_phase=$1
      readiness_now=$(monotonic_seconds)
      readiness_elapsed=$((readiness_now - readiness_started))
      readiness_grace=$(nfsd_timer /proc/fs/nfsd/nfsv4gracetime)
      readiness_lease=$(nfsd_timer /proc/fs/nfsd/nfsv4leasetime)
      printf 'phase=%s\nelapsed=%s\ngrace=%s\nlease=%s\n' \
        "$readiness_phase" "$readiness_elapsed" "$readiness_grace" "$readiness_lease" \
        > "$state/readiness.$$"
      mv -T "$state/readiness.$$" "$state/readiness"
    }

    readiness_emit() {
      readiness_snapshot "$1"
      printf 'readiness phase=%s elapsed=%ss grace=%s lease=%s\n' \
        "$readiness_phase" "$readiness_elapsed" "$readiness_grace" "$readiness_lease"
    }

    readiness_failure() {
      readiness_status=$1
      set +e
      readiness_snapshot "$readiness_phase"
      printf 'nfsd-sequence-operation: readiness failed phase=%s status=%s elapsed=%ss grace=%s lease=%s\n' \
        "$readiness_phase" "$readiness_status" "$readiness_elapsed" \
        "$readiness_grace" "$readiness_lease" >&2
      printf 'findmnt=' >&2
      timeout --kill-after=1 5 findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS \
        --mountpoint "$mount_main" >&2 || printf 'unavailable\n' >&2
      printf 'nfsd-threads=' >&2
      timeout --kill-after=1 5 cat /proc/fs/nfsd/threads >&2 \
        || printf 'unavailable\n' >&2
      printf 'dmesg-tail:\n' >&2
      timeout --kill-after=1 5 dmesg 2>&1 | tail -n 20 >&2
      exit "$readiness_status"
    }

    case "''${1-}" in
      prepare)
        test ! -e "$state" || fail "state already exists"
        install -d -m 0700 "$state"
        install -d -m 0755 "$mount_main" "$mount_fresh"
        ! mountpoint -q "$mount_main" || fail "persistent mount already exists"
        ! mountpoint -q "$mount_fresh" || fail "fresh mount already exists"
        timeout 30 mount -t nfs -o vers=4.1,proto=tcp 127.0.0.1:/ "$mount_main"
        findmnt -rn -o ID --mountpoint "$mount_main" > "$state/mount-id"
        mounted
        printf '%s\n' "$seed" > "$state/seed"
        expected=$(printf '%s\n' "$seed" | sha256sum | cut -d' ' -f1)
        readiness_started=$(monotonic_seconds)
        readiness_emit seed-readiness
        set +e
        timeout --kill-after=5 150 ${pkgs.bash}/bin/bash -c '
          set -euo pipefail
          state=$1
          mount_main=$2
          expected=$3
          dd if="$state/seed" of="$mount_main/seed.tmp" conv=fsync status=none
          mv "$mount_main/seed.tmp" "$mount_main/seed"
          actual=$(sha256sum "$mount_main/seed" | cut -d" " -f1)
          test "$actual" = "$expected"
        ' seed-readiness "$state" "$mount_main" "$expected"
        readiness_status=$?
        set -e
        test "$readiness_status" -eq 0 || readiness_failure "$readiness_status"
        integrity
        readiness_emit ready
        printf 'checksum=%s\n' "$expected"
        ;;
      start)
        mounted
        test ! -e "$state/pid" || fail "worker already exists"
        nohup "$0" worker > "$state/workload.log" 2>&1 < /dev/null &
        printf '%s\n' "$!" > "$state/pid"
        ;;
      worker)
        operations=0
        deadline=$((SECONDS + 600))
        trap 'status failed "$operations" -' ERR
        while test ! -e "$state/stop"; do
          test "$SECONDS" -lt "$deadline" || fail "workload deadline exceeded"
          mounted
          printf 'ordinary-nfs-operation-%08d\n' "$operations" > "$state/payload"
          dd if="$state/payload" of="$mount_main/operation.tmp" conv=fsync status=none
          mv -T "$mount_main/operation.tmp" "$mount_main/operation"
          cmp "$state/payload" "$mount_main/operation"
          integrity
          operations=$((operations + 1))
          status running "$operations" "$actual"
          sleep 0.05
        done
        integrity
        status stopped "$operations" "$actual"
        ;;
      checkpoint)
        mounted
        kill -0 "$(cat "$state/pid")" || fail "worker stopped"
        grep -Fx 'status=running' "$state/status" >/dev/null
        integrity
        cat "$state/status"
        ;;
      fresh)
        mounted
        ! mountpoint -q "$mount_fresh" || fail "fresh mount already exists"
        timeout 30 mount -t nfs -o vers=4.1,proto=tcp,nosharecache 127.0.0.1:/ "$mount_fresh"
        cmp "$state/seed" "$mount_fresh/seed"
        printf 'fresh-ordinary-operation\n' > "$state/fresh"
        dd if="$state/fresh" of="$mount_fresh/fresh.tmp" conv=fsync status=none
        mv -T "$mount_fresh/fresh.tmp" "$mount_fresh/fresh"
        cmp "$state/fresh" "$mount_fresh/fresh"
        timeout 30 umount "$mount_fresh"
        ;;
      stop)
        mounted
        pid=$(cat "$state/pid")
        kill -0 "$pid" || fail "worker stopped before cleanup"
        : > "$state/stop"
        timeout 30 tail --pid="$pid" -f /dev/null
        ! kill -0 "$pid" 2>/dev/null || fail "worker did not stop"
        grep -Fx 'status=stopped' "$state/status" >/dev/null
        integrity
        cat "$state/status"
        ;;
      cleanup)
        ! kill -0 "$(cat "$state/pid")" 2>/dev/null || fail "worker still running"
        ! mountpoint -q "$mount_fresh" || fail "fresh mount still active"
        timeout 30 umount "$mount_main"
        ! mountpoint -q "$mount_main" || fail "persistent mount still active"
        timeout 30 exportfs -ua
        timeout 30 rpc.nfsd 0
        timeout 30 sv stop nfsd
        test "$(cat /proc/fs/nfsd/threads)" = 0
        ;;
      *) fail "unsupported command" ;;
    esac
  '';

  oracleScript = ''
    require 'json'
    require 'shellwords'

    expected_set = JSON.parse(${builtins.toJSON (builtins.toJSON qualificationSet)})
    plan_sets = @plan.fetch('sets').select { |set| set.fetch('id') == ROW.fetch('setId') }
    captured_sets = @capture.fetch('sets').select { |set| set.fetch('id') == ROW.fetch('setId') }
    expect(plan_sets.length).to eq(1)
    expect(captured_sets.length).to eq(1)
    plan_set = plan_sets.fetch(0)
    captured_set = captured_sets.fetch(0)
    expect(plan_set).to eq(expected_set)
    expect(plan_set.fetch('kernelVersion')).to eq('6.12.48')
    expect(plan_set.fetch('members').length).to eq(1)
    expect(captured_set.fetch('members').length).to eq(plan_set.fetch('members').length)
    expect(ROW.fetch('scope')).to eq('fix')
    expect(ROW.fetch('role')).to eq('operation-safety')
    expect(ROW.fetch('oracleIds')).to eq(['nfsd-sequence-operation-safety'])
    expect(ROW.fetch('platformId')).to eq('amd')
    expect(ROW.fetch('runnerClass')).to eq('amd-livepatch')
    expect(ROW.fetch('supported')).to eq(true)

    member = captured_set.fetch('members').fetch(0)
    planned_member = plan_set.fetch('members').fetch(0)
    expect(planned_member.fetch('kernelVersion')).to eq(plan_set.fetch('kernelVersion'))
    expect(member.fetch('release')).to eq(planned_member.fetch('release'))
    expect(member.fetch('release')).to eq('6.12.48.1')
    identity = member.fetch('identity')
    expect(identity.keys.sort).to eq(%w[
      closureSha256 flakeLockSha256 inputDigest inspectionSha256 manifestSha256
      module moduleName moduleSha256 producer sourceRevision targetId vermagic
    ].sort)
    module_name = identity.fetch('moduleName')
    module_shell = Shellwords.escape(module_name)
    patch_dir = "/sys/kernel/livepatch/#{module_name}"
    evidence = "#{Shellwords.escape(identity.fetch('producer'))}/share/vpsadminos-livepatch"
    vendor = machine.succeeds("awk -F: '/vendor_id/{gsub(/ /, \"\", $2); print $2; exit}' /proc/cpuinfo")[1].strip
    expect(vendor).to eq('AuthenticAMD')
    machine.all_succeed(
      "test \"$(sha256sum #{Shellwords.escape(identity.fetch('module'))} | cut -d' ' -f1)\" = #{Shellwords.escape(identity.fetch('moduleSha256'))}",
      "test \"$(sha256sum #{evidence}/manifest.json | cut -d' ' -f1)\" = #{Shellwords.escape(identity.fetch('manifestSha256'))}",
      "test \"$(sha256sum #{evidence}/inspection.json | cut -d' ' -f1)\" = #{Shellwords.escape(identity.fetch('inspectionSha256'))}",
      "test \"$(sha256sum #{evidence}/closure.json | cut -d' ' -f1)\" = #{Shellwords.escape(identity.fetch('closureSha256'))}",
      "jq -e '.matches == true and .mismatches == {}' #{evidence}/closure.json",
      "jq -e --arg name #{module_shell} '.module.name == $name and .buildInvocation.nonReplaceRequested == true' #{evidence}/inspection.json",
      'test "$(uname -r)" = 6.12.48',
      "test ! -e #{Shellwords.escape(patch_dir)} && test ! -e /sys/module/#{module_shell}",
      'sv check nfsd',
    )

    def nfsd_inventory(machine, module_name, state)
      rows = machine.succeeds('live-patches status')[1].lines.grep(/^ordinal=/)
      raise 'unexpected manager inventory' unless rows.length == 1
      fields = rows.fetch(0).split.to_h { |field| field.split('=', 2) }
      expected = {
        'ordinal' => '1', 'release' => '6.12.48.1', 'module' => module_name,
        'configured' => 'yes', 'state' => state,
      }
      expected.each { |key, value| raise "manager #{key} mismatch" unless fields.fetch(key) == value }
      if state == 'active'
        raise 'manager state is not converged' unless fields.values_at('present', 'enabled', 'transition', 'replace') == %w[yes 1 0 0]
      else
        raise 'manager module remains present' unless fields.fetch('present') == 'no'
      end
    end

    def nfsd_progress(machine, previous = 0)
      machine.wait_until_succeeds(
        "nfsd-sequence-operation checkpoint | awk -F= '/^operations=/{if ($2 > #{previous}) ok=1} END {exit !ok}'",
        timeout: 30,
      )
      checkpoint = machine.succeeds('nfsd-sequence-operation checkpoint')[1]
      Integer(checkpoint.match(/^operations=([0-9]+)$/).captures.fetch(0), 10)
    end

    nfsd_inventory(machine, module_name, 'configured-not-loaded')
    dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i
    prepared = machine.succeeds('nfsd-sequence-operation prepare', timeout: 210)[1]
    checksum = prepared.match(/^checksum=([0-9a-f]{64})$/).captures.fetch(0)
    machine.succeeds('nfsd-sequence-operation start')
    native_progress = nfsd_progress(machine)

    machine.succeeds('live-patches load 1', timeout: 240)
    machine.all_succeed(
      "test \"$(cat #{Shellwords.escape(patch_dir)}/enabled)\" = 1",
      "test \"$(cat #{Shellwords.escape(patch_dir)}/transition)\" = 0",
      "test \"$(cat #{Shellwords.escape(patch_dir)}/replace)\" = 0",
      'test "$(uname -r)" = 6.12.48.1',
      'sv check nfsd',
    )
    nfsd_inventory(machine, module_name, 'active')
    forward_progress = nfsd_progress(machine, native_progress)
    machine.succeeds('nfsd-sequence-operation fresh', timeout: 90)
    before_reverse = nfsd_progress(machine, forward_progress)

    machine.succeeds('live-patches unload 1', timeout: 240)
    machine.all_succeed(
      "test ! -e #{Shellwords.escape(patch_dir)} && test ! -e /sys/module/#{module_shell}",
      'test "$(uname -r)" = 6.12.48',
      'sv check nfsd',
    )
    nfsd_inventory(machine, module_name, 'configured-not-loaded')
    reverse_progress = nfsd_progress(machine, before_reverse)
    machine.succeeds('nfsd-sequence-operation fresh', timeout: 90)
    stopped = machine.succeeds('nfsd-sequence-operation stop', timeout: 60)[1]
    expect(stopped.match(/^checksum=([0-9a-f]{64})$/).captures.fetch(0)).to eq(checksum)
    final_progress = Integer(stopped.match(/^operations=([0-9]+)$/).captures.fetch(0), 10)
    expect(final_progress).to be >= reverse_progress
    machine.succeeds('nfsd-sequence-operation cleanup', timeout: 120)

    noise = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)|NFS:.*(?:fatal|error)|RPC:.*(?:fatal|error)/
    expect(machine.succeeds("dmesg | tail -n +#{dmesg_start + 1}")[1]).not_to match(noise)
    marker = {
      schemaVersion: 1,
      oracleId: 'nfsd-sequence-operation-safety',
      platformId: ROW.fetch('platformId'), runnerClass: ROW.fetch('runnerClass'),
      rowId: ROW.fetch('rowId'), setId: ROW.fetch('setId'),
      release: member.fetch('release'), nativeRelease: plan_set.fetch('kernelVersion'),
      identity: identity,
      workload: {
        protocol: '4.1', transport: 'tcp', mounts: 1, freshMounts: 2,
        continuous: true, integritySha256: checksum,
        progress: {
          native: native_progress, forward: forward_progress,
          beforeReverse: before_reverse, reverse: reverse_progress, final: final_progress,
        },
      },
      forward: { enabled: 1, transition: 0, replace: 0, release: member.fetch('release') },
      reverse: { moduleRemoved: true, release: plan_set.fetch('kernelVersion') },
      cleanup: { workerStopped: true, mountsRemoved: true, serverStopped: true },
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
        system.activationScripts.nfsdSequenceQualification = ''
          ${pkgs.coreutils}/bin/install -d -m 0755 /srv/nfsd-sequence
        '';
        services.nfs.server = {
          enable = true;
          nfsd.allowedVersions = [ "4.1" ];
          exports = ''
            /srv/nfsd-sequence 127.0.0.1(rw,sync,no_subtree_check,no_root_squash,insecure,fsid=0)
          '';
        };
        environment.systemPackages = [
          operationTool
          pkgs.coreutils
          pkgs.diffutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.nfs-utils
          pkgs.util-linux
        ];
      }
    )
  ];
  oracleScripts.operation-safety = oracleScript;
}

{
  capture,
  oracle,
  plan,
  pkgs,
  qualificationSet,
  row,
}:

let
  operationTool = pkgs.writeShellScriptBin "nfsd-openowner-operation" ''
    set -euo pipefail

    state_dir=/run/nfsd-openowner-operation
    mount_a=/mnt/nfsd-openowner-a
    mount_b=/mnt/nfsd-openowner-b
    mount_fresh=/mnt/nfsd-openowner-fresh
    seed=livepatch-nfsd-openowner-integrity-v1

    fail() {
      echo "nfsd-openowner-operation: $*" >&2
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
          exec 9> "$mount_a/openowner-a"
          flock -x 9
          printf 'a-%08d\n' "$operations" >&9
          sync -f "$mount_a/openowner-a"
          flock -u 9
          exec 9>&-

          exec 8> "$mount_b/openowner-b"
          flock -x 8
          printf 'b-%08d\n' "$operations" >&8
          sync -f "$mount_b/openowner-b"
          flock -u 8
          exec 8>&-

          cmp -s "$mount_a/seed" "$mount_b/seed"
          stat "$mount_a/openowner-a" "$mount_b/openowner-b" >/dev/null
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
        phase=''${2-}
        test -n "$phase" || fail "operation phase is missing"
        require_mounted
        expected=$(printf '%s\n' "$seed" | sha256sum | cut -d' ' -f1)
        actual=$(sha256sum "$mount_b/seed" | cut -d' ' -f1)
        test "$actual" = "$expected" || fail "checksum mismatch"

        exec 7> "$mount_a/serial-openowner"
        flock -x 7
        printf '%s\n' "$phase" >&7
        sync -f "$mount_a/serial-openowner"
        stat "$mount_b/serial-openowner" >/dev/null
        flock -u 7
        exec 7>&-

        ! mountpoint -q "$mount_fresh" || fail "$mount_fresh is already mounted"
        mount -t nfs -o vers=4.2,proto=tcp 127.0.0.1:/ "$mount_fresh"
        actual=$(sha256sum "$mount_fresh/seed" | cut -d' ' -f1)
        test "$actual" = "$expected" || fail "fresh checksum mismatch"
        printf '%s\n' "$phase" > "$mount_fresh/reconnect-$phase.tmp"
        dd if="$mount_fresh/reconnect-$phase.tmp" \
          of="$mount_fresh/reconnect-$phase" conv=fsync status=none
        rm -f "$mount_fresh/reconnect-$phase.tmp"
        stat "$mount_fresh/reconnect-$phase" >/dev/null
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
        ! mountpoint -q "$mount_fresh" || fail "$mount_fresh is still active"
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

    oracle_id = 'nfsd-openowner-operation-safety'
    expected_set = JSON.parse(${builtins.toJSON expectedSetJson})
    plan_sets = @plan.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }
    captured_sets = @capture.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }
    expect(plan_sets.length).to eq(1)
    expect(captured_sets.length).to eq(1)
    plan_set = plan_sets.fetch(0)
    captured_set = captured_sets.fetch(0)
    expect(plan_set).to eq(expected_set)
    expect(ROW.fetch('scope')).to eq('fix')
    expect(ROW.fetch('role')).to eq('operation-safety')
    expect(ROW.fetch('oracleIds')).to eq([oracle_id])
    expect(ROW.fetch('supported')).to eq(true)

    planned_releases = plan_set.fetch('members').map { |member| member.fetch('release') }
    captured_members = captured_set.fetch('members')
    expect(planned_releases).to eq(['6.12.113.1', '6.12.113.2'])
    expect(captured_members.map { |member| member.fetch('release') }).to eq(planned_releases)

    expected_vendor = {
      'amd' => 'AuthenticAMD',
      'intel' => 'GenuineIntel',
    }.fetch(ROW.fetch('platformId'))
    vendor = machine.succeeds("awk -F: '/vendor_id/{gsub(/ /, \"\", $2); print $2; exit}' /proc/cpuinfo")[1].strip
    expect(vendor).to eq(expected_vendor)

    captured_members.each do |member|
      identity = member.fetch('identity')
      producer = Shellwords.escape(identity.fetch('producer'))
      module_path = Shellwords.escape(identity.fetch('module'))
      evidence = "#{producer}/share/vpsadminos-livepatch"
      machine.all_succeed(
        "test -f #{module_path}",
        "test \"$(sha256sum #{module_path} | cut -d' ' -f1)\" = #{identity.fetch('moduleSha256')}",
        "jq -e '.matches == true and .mismatches == {}' #{evidence}/closure.json",
      )
    end

    def wait_nfsd_forward(machine, module_name)
      patch_dir = "/sys/kernel/livepatch/#{module_name}"
      machine.wait_until_succeeds(
        "test -d #{Shellwords.escape(patch_dir)} && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/enabled)\" = 1 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/transition)\" = 0 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/replace)\" = 0",
        timeout: 180,
      )
    end

    dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i
    prepare = machine.succeeds('nfsd-openowner-operation prepare')[1]
    integrity_match = prepare.match(/^checksum=([0-9a-f]{64})$/)
    expect(integrity_match).not_to be_nil
    integrity_sha256 = integrity_match[1]
    machine.succeeds('nfsd-openowner-operation start')

    captured_members.each do |member|
      identity = member.fetch('identity')
      machine.succeeds("insmod #{Shellwords.escape(identity.fetch('module'))}", timeout: 60)
      wait_nfsd_forward(machine, identity.fetch('moduleName'))
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(member.fetch('release'))}")
    end
    machine.succeeds('nfsd-openowner-operation operate after-forward')

    captured_members.reverse_each do |member|
      identity = member.fetch('identity')
      module_name = identity.fetch('moduleName')
      patch_dir = "/sys/kernel/livepatch/#{module_name}"
      machine.succeeds("sh -c 'echo 0 > #{Shellwords.escape(patch_dir)}/enabled'", timeout: 60)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && test -d /sys/module/#{Shellwords.escape(module_name)}",
        timeout: 180,
      )
      machine.succeeds("rmmod #{Shellwords.escape(module_name)}", timeout: 60)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && test ! -d /sys/module/#{Shellwords.escape(module_name)}",
        timeout: 180,
      )
    end
    machine.succeeds('test "$(uname -r)" = 6.12.113')
    machine.succeeds('nfsd-openowner-operation operate after-reverse')

    workload = machine.succeeds('nfsd-openowner-operation stop')[1]
    operations_match = workload.match(/^operations=([0-9]+)$/)
    checksum_match = workload.match(/^checksum=([0-9a-f]{64})$/)
    expect(operations_match).not_to be_nil
    expect(checksum_match).not_to be_nil
    operations = Integer(operations_match[1], 10)
    expect(operations).to be > 0
    expect(checksum_match[1]).to eq(integrity_sha256)
    machine.succeeds('nfsd-openowner-operation cleanup')

    kernel_output = machine.succeeds("dmesg | tail -n +#{dmesg_start + 1}")[1]
    fatal_pattern = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)|NFS:.*(?:fatal|error)|NFSD:.*(?:fatal|error)|RPC:.*(?:fatal|error)/
    expect(kernel_output).not_to match(fatal_pattern)

    marker = {
      schemaVersion: 1,
      oracleId: oracle_id,
      platformId: ROW.fetch('platformId'),
      runnerClass: ROW.fetch('runnerClass'),
      rowId: ROW.fetch('rowId'),
      setId: ROW.fetch('setId'),
      release: '6.12.113.2',
      nativeRelease: '6.12.113',
      members: captured_members.map { |member| member.fetch('identity') },
      workload: {
        operations: operations,
        integritySha256: integrity_sha256,
        operation: oracle_id,
      },
      forward: {
        release: '6.12.113.2',
        converged: true,
      },
      reverse: {
        release: '6.12.113',
        modulesRemoved: true,
      },
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
        system.activationScripts.nfsdOpenownerQualification = ''
          ${pkgs.coreutils}/bin/install -d -m 0755 /srv/nfsd-openowner
        '';
        services.nfs.server = {
          enable = true;
          nfsd.allowedVersions = [ "4.2" ];
          exports = ''
            /srv/nfsd-openowner 127.0.0.1(rw,sync,no_subtree_check,no_root_squash,insecure,fsid=0)
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

  oracleScripts.operation-safety = oracleScript;
}

{
  capture,
  oracle,
  plan,
  pkgs,
  qualificationSet,
  row,
}:

let
  operationTool = pkgs.writeShellScriptBin "ceph-livepatch-operation" ''
        set -euo pipefail

        state_dir=/run/ceph-livepatch-operation
        data_dir=/var/lib/ceph-livepatch-operation
        mount_main=/mnt/ceph-livepatch
        mount_fresh=/mnt/ceph-livepatch-fresh
        conf="$state_dir/ceph.conf"
        admin_keyring="$state_dir/client.admin.keyring"
        secret_file="$state_dir/client.admin.secret"
        seed=livepatch-ceph-integrity-v1

        fail() {
          echo "ceph-livepatch-operation: $*" >&2
          exit 1
        }

        ceph_cmd() {
          ceph --conf "$conf" --name client.admin --keyring "$admin_keyring" "$@"
        }

        wait_for() {
          description=$1
          shift
          for unused in $(seq 1 120); do
            if "$@"; then
              return 0
            fi
            sleep 1
          done
          fail "timed out waiting for $description"
        }

        daemon_alive() {
          pid_file=$1
          test -s "$pid_file" || return 1
          pid=$(cat "$pid_file")
          [[ "$pid" =~ ^[0-9]+$ ]] || return 1
          kill -0 "$pid" 2>/dev/null
        }

        start_daemon() {
          name=$1
          shift
          log="$state_dir/$name.log"
          pid_file="$state_dir/$name.pid"
          test ! -e "$pid_file" || fail "$name pid file already exists"
          nohup "$@" > "$log" 2>&1 < /dev/null &
          pid=$!
          printf '%s\n' "$pid" > "$pid_file"
          kill -0 "$pid" || fail "$name did not start"
        }

        stop_daemon() {
          name=$1
          pid_file="$state_dir/$name.pid"
          daemon_alive "$pid_file" || return 0
          pid=$(cat "$pid_file")
          kill "$pid"
          for unused in $(seq 1 30); do
            ! kill -0 "$pid" 2>/dev/null && return 0
            sleep 1
          done
          fail "$name did not stop"
        }

        mount_ceph() {
          target=$1
          ! mountpoint -q "$target" || fail "$target is already mounted"
          mount -t ceph 127.0.0.1:6789:/ "$target" \
            -o name=admin,secretfile="$secret_file",fs=ceph
        }

        active_mds_count() {
          ceph_cmd mds stat 2>/dev/null | grep -o 'up:active' | wc -l
        }

        active_mds_is() {
          expected=$1
          test "$(active_mds_count)" -eq "$expected"
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
            install -d -m 0755 "$data_dir" "$mount_main" "$mount_fresh"
            test ! -e "$state_dir/prepared" || fail "operation is already prepared"

            fsid=11111111-2222-3333-4444-555555555555
            cat > "$conf" <<EOF
    [global]
    fsid = $fsid
    mon initial members = a
    mon host = 127.0.0.1:6789
    public network = 127.0.0.0/8
    auth cluster required = cephx
    auth service required = cephx
    auth client required = cephx
    osd pool default size = 1
    osd pool default min size = 1
    osd pool default pg num = 8
    osd pool default pgp num = 8
    osd crush chooseleaf type = 0
    osd objectstore = memstore
    ms bind ipv6 = false
    EOF

            ceph-authtool --create-keyring "$state_dir/mon.keyring" \
              --gen-key -n mon. --cap mon 'allow *'
            ceph-authtool --create-keyring "$admin_keyring" \
              --gen-key -n client.admin \
              --cap mon 'allow *' --cap mgr 'allow *' \
              --cap osd 'allow *' --cap mds 'allow *'
            ceph-authtool "$state_dir/mon.keyring" --import-keyring "$admin_keyring"
            ceph-authtool "$admin_keyring" -n client.admin --print-key > "$secret_file"
            chmod 0600 "$secret_file"

            monmaptool --create --add a 127.0.0.1:6789 --fsid "$fsid" \
              "$state_dir/monmap"
            install -d -m 0755 "$data_dir/mon-a"
            ceph-mon --mkfs -i a --conf "$conf" --mon-data "$data_dir/mon-a" \
              --monmap "$state_dir/monmap" --keyring "$state_dir/mon.keyring"
            start_daemon mon-a ceph-mon -f -i a --conf "$conf" \
              --mon-data "$data_dir/mon-a" --setuser root --setgroup root
            wait_for monitor ceph_cmd status

            osd_uuid=22222222-3333-4444-5555-666666666666
            ceph_cmd osd create "$osd_uuid" 0 >/dev/null
            ceph_cmd auth get-or-create osd.0 \
              mon 'allow profile osd' mgr 'allow profile osd' osd 'allow *' \
              -o "$state_dir/osd.0.keyring"
            install -d -m 0755 "$data_dir/osd-0"
            ceph-osd --mkfs -i 0 --conf "$conf" --osd-data "$data_dir/osd-0" \
              --osd-uuid "$osd_uuid" --osd-objectstore memstore \
              --keyring "$state_dir/osd.0.keyring"
            start_daemon osd-0 ceph-osd -f -i 0 --conf "$conf" \
              --osd-data "$data_dir/osd-0" --osd-objectstore memstore \
              --keyring "$state_dir/osd.0.keyring" --setuser root --setgroup root
            wait_for osd sh -c \
              "ceph --conf '$conf' --name client.admin --keyring '$admin_keyring' osd stat | grep -q '1 up, 1 in'"

            ceph_cmd osd pool create cephfs_metadata 8 >/dev/null
            ceph_cmd osd pool create cephfs_data 8 >/dev/null
            ceph_cmd fs new cephfs cephfs_metadata cephfs_data >/dev/null
            for mds_id in a b; do
              ceph_cmd auth get-or-create "mds.$mds_id" \
                mon 'allow profile mds' mgr 'allow profile mds' \
                mds 'allow' osd 'allow rwx' \
                -o "$state_dir/mds.$mds_id.keyring"
              install -d -m 0755 "$data_dir/mds-$mds_id"
              start_daemon "mds-$mds_id" ceph-mds -f -i "$mds_id" \
                --conf "$conf" --mds-data "$data_dir/mds-$mds_id" \
                --keyring "$state_dir/mds.$mds_id.keyring" \
                --setuser root --setgroup root
            done
            wait_for active-mds active_mds_is 1

            mount_ceph "$mount_main"
            printf '%s\n' "$seed" > "$mount_main/seed.tmp"
            dd if="$mount_main/seed.tmp" of="$mount_main/seed" conv=fsync status=none
            rm -f "$mount_main/seed.tmp"
            expected=$(printf '%s\n' "$seed" | sha256sum | cut -d' ' -f1)
            actual=$(sha256sum "$mount_main/seed" | cut -d' ' -f1)
            test "$actual" = "$expected" || fail "initial checksum mismatch"
            : > "$state_dir/prepared"
            printf 'checksum=%s\n' "$expected"
            ;;

          start)
            test -e "$state_dir/prepared" || fail "operation is not prepared"
            test ! -e "$state_dir/pid" || fail "workload pid already exists"
            test ! -e "$state_dir/status" || fail "workload status already exists"
            test ! -e "$state_dir/stop" || fail "workload stop already exists"
            nohup "$0" worker > "$state_dir/workload.log" 2>&1 < /dev/null &
            pid=$!
            printf '%s\n' "$pid" > "$state_dir/pid"
            kill -0 "$pid"
            ;;

          worker)
            mountpoint -q "$mount_main" || fail "$mount_main is not mounted"
            operations=0
            while test ! -e "$state_dir/stop"; do
              printf 'ceph-%08d\n' "$operations" > "$mount_main/io.tmp"
              dd if="$mount_main/io.tmp" of="$mount_main/io" conv=fsync status=none
              rm -f "$mount_main/io.tmp"
              grep -Fx "$seed" "$mount_main/seed" >/dev/null
              stat "$mount_main/io" "$mount_main/seed" >/dev/null
              stat -f "$mount_main" >/dev/null
              operations=$((operations + 1))
              if test "$operations" -ge 20000; then
                write_status exhausted "$operations" -
                exit 1
              fi
            done
            checksum=$(sha256sum "$mount_main/seed" | cut -d' ' -f1)
            write_status ok "$operations" "$checksum"
            ;;

          operate)
            oracle_id=''${2-}
            phase=''${3-}
            test -n "$oracle_id" || fail "oracle id is missing"
            test -n "$phase" || fail "operation phase is missing"
            mountpoint -q "$mount_main" || fail "$mount_main is not mounted"
            expected=$(printf '%s\n' "$seed" | sha256sum | cut -d' ' -f1)
            actual=$(sha256sum "$mount_main/seed" | cut -d' ' -f1)
            test "$actual" = "$expected" || fail "checksum mismatch"

            case "$oracle_id" in
              cephx-auth-operation-safety)
                mount_ceph "$mount_fresh"
                cmp -s "$mount_main/seed" "$mount_fresh/seed"
                stat "$mount_fresh/seed" >/dev/null
                umount "$mount_fresh"
                ;;
              ceph-monitor-command-operation-safety)
                stat -f "$mount_main" >/dev/null
                ceph_cmd fs get cephfs >/dev/null
                ceph_cmd mds stat >/dev/null
                ;;
              ceph-snapshot-operation-safety)
                snapshot="$mount_main/.snap/livepatch-$phase"
                mkdir "$snapshot"
                test -r "$snapshot/seed"
                ls -la "$mount_main/.snap" >/dev/null
                rmdir "$snapshot"
                ;;
              ceph-mdsmap-operation-safety)
                ceph_cmd fs set cephfs max_mds 2 >/dev/null
                wait_for two-active-mds active_mds_is 2
                ceph_cmd fs set cephfs max_mds 1 >/dev/null
                wait_for one-active-mds active_mds_is 1
                ;;
              ceph-dentry-lease-operation-safety)
                printf '%s\n' "$phase" > "$mount_main/lease-$phase.tmp"
                mv "$mount_main/lease-$phase.tmp" "$mount_main/lease-$phase"
                stat "$mount_main/lease-$phase" >/dev/null
                cat "$mount_main/lease-$phase" >/dev/null
                rm -f "$mount_main/lease-$phase"
                ;;
              *)
                fail "unsupported oracle id: $oracle_id"
                ;;
            esac
            ;;

          stop)
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
            test ! -e "$state_dir/pid" || {
              pid=$(cat "$state_dir/pid")
              ! kill -0 "$pid" 2>/dev/null || fail "workload is still running"
            }
            ! mountpoint -q "$mount_fresh" || umount "$mount_fresh"
            ! mountpoint -q "$mount_main" || umount "$mount_main"
            for name in mds-b mds-a osd-0 mon-a; do
              stop_daemon "$name"
            done
            ;;

          *)
            fail "unsupported command: $command"
            ;;
        esac
  '';

  expectedSetJson = builtins.toJSON qualificationSet;
  oracleId = oracle.id;
  oracleScript = ''
    require 'json'
    require 'shellwords'

    oracle_id = ${builtins.toJSON oracleId}

    def validate_storage_capture_relation(plan_set, captured_set)
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
    validate_storage_capture_relation(plan_set, captured_set)
    expect(ROW.fetch('scope')).to eq('fix')
    expect(ROW.fetch('role')).to eq('operation-safety')
    expect(ROW.fetch('oracleIds')).to eq([oracle_id])
    expect(ROW.fetch('supported')).to eq(true)

    planned_releases = plan_set.fetch('members').map { |member| member.fetch('release') }
    captured_members = captured_set.fetch('members')
    expect(captured_members.map { |member| member.fetch('release') }).to eq(planned_releases)

    expected_vendor = {
      'amd' => 'AuthenticAMD',
      'intel' => 'GenuineIntel',
    }.fetch(ROW.fetch('platformId'))
    vendor = machine.succeeds("awk -F: '/vendor_id/{gsub(/ /, \"\", $2); print $2; exit}' /proc/cpuinfo")[1].strip
    expect(vendor).to eq(expected_vendor)

    captured_members.each do |member|
      identity = member.fetch('identity')
      expect(identity.keys.sort).to eq(%w[
        closureSha256 flakeLockSha256 inputDigest inspectionSha256 manifestSha256
        module moduleName moduleSha256 producer sourceRevision targetId vermagic
      ].sort)
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
        "test ! -e /sys/kernel/livepatch/#{module_name}",
      )
    end

    def wait_ceph_transition(machine, module_name, enabled)
      patch_dir = "/sys/kernel/livepatch/#{module_name}"
      machine.wait_until_succeeds(
        "test -d #{Shellwords.escape(patch_dir)} && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/enabled)\" = #{enabled} && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/transition)\" = 0 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/replace)\" = 0",
        timeout: 180,
      )
    end

    machine.succeeds('test "$(uname -r)" = 6.12.113')
    dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i
    prepare = machine.succeeds('ceph-livepatch-operation prepare', timeout: 300)[1]
    integrity_match = prepare.match(/^checksum=([0-9a-f]{64})$/)
    expect(integrity_match).not_to be_nil
    integrity_sha256 = integrity_match[1]
    machine.succeeds('ceph-livepatch-operation start')

    forward = captured_members.map do |member|
      identity = member.fetch('identity')
      machine.succeeds("insmod #{Shellwords.escape(identity.fetch('module'))}", timeout: 60)
      wait_ceph_transition(machine, identity.fetch('moduleName'), 1)
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(member.fetch('release'))}")
      machine.succeeds(
        "ceph-livepatch-operation operate #{Shellwords.escape(oracle_id)} " \
          "#{Shellwords.escape("after-forward-#{member.fetch('release')}")}",
        timeout: 180,
      )
      {
        release: member.fetch('release'),
        enabled: 1,
        transition: 0,
        replace: 0,
      }
    end

    reverse = captured_members.each_index.reverse_each.map do |index|
      member = captured_members.fetch(index)
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
      predecessor_release = index.zero? ? '6.12.113' : captured_members.fetch(index - 1).fetch('release')
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(predecessor_release)}")
      machine.succeeds(
        "ceph-livepatch-operation operate #{Shellwords.escape(oracle_id)} " \
          "#{Shellwords.escape("after-reverse-#{member.fetch('release')}")}",
        timeout: 180,
      )
      {
        removedRelease: member.fetch('release'),
        release: predecessor_release,
        moduleRemoved: true,
      }
    end

    workload = machine.succeeds('ceph-livepatch-operation stop')[1]
    operations_match = workload.match(/^operations=([0-9]+)$/)
    checksum_match = workload.match(/^checksum=([0-9a-f]{64})$/)
    expect(operations_match).not_to be_nil
    expect(checksum_match).not_to be_nil
    operations = Integer(operations_match[1], 10)
    expect(operations).to be > 0
    expect(checksum_match[1]).to eq(integrity_sha256)
    machine.succeeds('ceph-livepatch-operation cleanup', timeout: 60)

    kernel_output = machine.succeeds("dmesg | tail -n +#{dmesg_start + 1}")[1]
    fatal_pattern = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)|ceph:.*(?:fatal|error)|libceph:.*(?:fatal|error)/
    expect(kernel_output).not_to match(fatal_pattern)

    marker = {
      schemaVersion: 1,
      oracleId: oracle_id,
      platformId: ROW.fetch('platformId'),
      runnerClass: ROW.fetch('runnerClass'),
      rowId: ROW.fetch('rowId'),
      setId: ROW.fetch('setId'),
      release: plan_set.fetch('tipRelease'),
      nativeRelease: '6.12.113',
      memberReleases: captured_members.map { |member| member.fetch('release') },
      members: captured_members.map { |member| member.fetch('identity') },
      workload: {
        operations: operations,
        integritySha256: integrity_sha256,
        operation: oracle_id,
      },
      forward: {
        release: plan_set.fetch('tipRelease'),
        converged: true,
        boundaries: forward,
      },
      reverse: {
        release: '6.12.113',
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
      { pkgs, ... }:
      {
        environment.systemPackages = [
          operationTool
          pkgs.ceph
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.util-linux
        ];
      }
    )
  ];

  oracleScripts.operation-safety = oracleScript;
}

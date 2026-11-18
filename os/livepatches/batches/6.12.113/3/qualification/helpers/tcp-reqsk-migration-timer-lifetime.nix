{
  capture,
  oracle,
  plan,
  pkgs,
  qualificationSet,
  row,
  profile ? { },
}:

let
  effectiveProfile = {
    fixId = "tcp-reqsk-migration-timer-lifetime";
    oracleId = "tcp-reqsk-migration-timer-operation-safety";
    toolName = "tcp-reqsk-migration-timer-operation";
    operationLabel = "IPv4 and IPv6 request migration timer lifecycle";
  }
  // profile;

  inherit (effectiveProfile)
    fixId
    operationLabel
    oracleId
    toolName
    ;

  tcpOperation = pkgs.writeText "tcp-reqsk-operation.py" ''
    import json
    import os
    import socket
    import sys
    import tempfile
    import time

    PAYLOAD = b"vpsadminos-livepatch-reqsk"
    REQUEST_COUNT = 8
    TIMER_MIGRATION_TIMEOUT = 10


    def endpoint(family):
        return "127.0.0.1" if family == socket.AF_INET else "::1"


    def listener(family):
        sock = socket.socket(family, socket.SOCK_STREAM)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        return sock


    def receive_exact(sock, size):
        data = b""
        while len(data) < size:
            part = sock.recv(size - len(data))
            if not part:
                raise RuntimeError("connection closed before complete data")
            data += part
        return data


    def namespace_identity():
        return os.readlink("/proc/self/ns/net")


    def tcp_ext_counters():
        with open("/proc/self/net/netstat", encoding="ascii") as netstat:
            rows = netstat.read().splitlines()

        for index, header in enumerate(rows[:-1]):
            if not header.startswith("TcpExt:"):
                continue
            values = rows[index + 1]
            if not values.startswith("TcpExt:"):
                continue
            names = header.split()[1:]
            counts = values.split()[1:]
            if len(names) != len(counts):
                raise RuntimeError("TcpExt counter names and values differ")
            counters = dict(zip(names, map(int, counts), strict=True))
            try:
                return {
                    "TCPMigrateReqSuccess": counters["TCPMigrateReqSuccess"],
                    "TCPMigrateReqFailure": counters["TCPMigrateReqFailure"],
                }
            except KeyError as error:
                raise RuntimeError(f"missing TcpExt counter: {error.args[0]}") from error

        raise RuntimeError("TcpExt counters are missing")


    def counter_record(baseline, final, name):
        return {
            "baseline": baseline[name],
            "final": final[name],
            "delta": final[name] - baseline[name],
        }


    def wait_for_timer_migration(baseline):
        deadline = time.monotonic() + TIMER_MIGRATION_TIMEOUT
        while True:
            final = tcp_ext_counters()
            success = final["TCPMigrateReqSuccess"] - baseline["TCPMigrateReqSuccess"]
            failure = final["TCPMigrateReqFailure"] - baseline["TCPMigrateReqFailure"]
            if failure != 0:
                raise RuntimeError("request migration failure counter changed")
            if success == REQUEST_COUNT:
                return final
            if success > REQUEST_COUNT:
                raise RuntimeError("request migration success counter exceeded request count")
            if time.monotonic() >= deadline:
                raise RuntimeError("request timer migration counter did not reach request count")
            time.sleep(0.05)


    def exchange(family, fast_open):
        server = listener(family)
        try:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if fast_open:
                server.setsockopt(socket.IPPROTO_TCP, socket.TCP_FASTOPEN, 8)
            server.bind((endpoint(family), 0))
            server.listen(8)
            address = server.getsockname()

            client = socket.socket(family, socket.SOCK_STREAM)
            try:
                client.settimeout(10)
                if fast_open:
                    sent = client.sendto(PAYLOAD, socket.MSG_FASTOPEN, address)
                    if sent < len(PAYLOAD):
                        client.sendall(PAYLOAD[sent:])
                else:
                    client.connect(address)
                    client.sendall(PAYLOAD)

                connection, _ = server.accept()
                try:
                    connection.settimeout(10)
                    if receive_exact(connection, len(PAYLOAD)) != PAYLOAD:
                        raise RuntimeError("server payload mismatch")
                    connection.sendall(PAYLOAD[::-1])
                finally:
                    connection.close()

                if receive_exact(client, len(PAYLOAD)) != PAYLOAD[::-1]:
                    raise RuntimeError("client payload mismatch")
            finally:
                client.close()
        finally:
            server.close()


    def migrate_deferred_requests(family):
        primary = listener(family)
        successor = listener(family)
        clients = []
        accepted = []
        evidence = None
        try:
            for sock in (primary, successor):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_DEFER_ACCEPT, 1)

            primary.bind((endpoint(family), 0))
            address = primary.getsockname()
            successor.bind(address)
            primary.listen(32)

            namespace_before = namespace_identity()
            baseline = tcp_ext_counters()

            for _ in range(REQUEST_COUNT):
                client = socket.socket(family, socket.SOCK_STREAM)
                client.settimeout(10)
                client.connect(address)
                clients.append(client)

            successor.listen(32)
            successor.settimeout(10)
            primary.close()
            primary = None
            final = wait_for_timer_migration(baseline)
            namespace_after = namespace_identity()
            if namespace_after != namespace_before:
                raise RuntimeError("operation network namespace changed")

            for client in clients:
                client.sendall(PAYLOAD)

            for _ in clients:
                connection, _ = successor.accept()
                accepted.append(connection)
                connection.settimeout(10)
                if receive_exact(connection, len(PAYLOAD)) != PAYLOAD:
                    raise RuntimeError("migrated request payload mismatch")
                connection.sendall(PAYLOAD[::-1])

            round_trips = 0
            for client in clients:
                if receive_exact(client, len(PAYLOAD)) != PAYLOAD[::-1]:
                    raise RuntimeError("migrated response payload mismatch")
                round_trips += 1

            evidence = {
                "family": "ipv4" if family == socket.AF_INET else "ipv6",
                "counterSource": "/proc/self/net/netstat",
                "counterScope": "process-network-namespace",
                "namespace": {
                    "source": "/proc/self/ns/net",
                    "baseline": namespace_before,
                    "final": namespace_after,
                },
                "requestCount": REQUEST_COUNT,
                "TCPMigrateReqSuccess": counter_record(
                    baseline, final, "TCPMigrateReqSuccess"
                ),
                "TCPMigrateReqFailure": counter_record(
                    baseline, final, "TCPMigrateReqFailure"
                ),
                "acceptedCount": len(accepted),
                "roundTripCount": round_trips,
            }
        finally:
            for connection in accepted:
                connection.close()
            for client in clients:
                client.close()
            if primary is not None:
                primary.close()
            successor.close()

        return evidence


    def write_evidence(path, operation, families):
        directory = os.path.dirname(path)
        descriptor, temporary = tempfile.mkstemp(prefix=".evidence.", dir=directory)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(
                    {
                        "schemaVersion": 1,
                        "operation": operation,
                        "families": families,
                    },
                    output,
                    separators=(",", ":"),
                    sort_keys=True,
                )
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
        except BaseException:
            try:
                os.close(descriptor)
            except OSError:
                pass
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise


    if len(sys.argv) != 3:
        raise SystemExit("usage: tcp-reqsk-operation.py EVIDENCE OPERATION")
    evidence_path = sys.argv[1]
    operation_number = int(sys.argv[2])
    if operation_number <= 0:
        raise RuntimeError("operation number must be positive")

    family_evidence = []
    for address_family in (socket.AF_INET, socket.AF_INET6):
        exchange(address_family, False)
        exchange(address_family, True)
        family_evidence.append(migrate_deferred_requests(address_family))

    if family_evidence[0]["namespace"]["final"] != family_evidence[1]["namespace"]["baseline"]:
        raise RuntimeError("IPv4 and IPv6 operations used different network namespaces")
    write_evidence(evidence_path, operation_number, family_evidence)
  '';

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

    command=''${1-}
    case "$command" in
      prepare)
        test ! -e "$state_dir/pid" || fail "workload pid already exists"
        test "$(cat /proc/sys/net/ipv4/tcp_syncookies)" = 2 \
          || fail "tcp_syncookies is not 2"
        test "$(cat /proc/sys/net/ipv4/tcp_fastopen)" = 3 \
          || fail "tcp_fastopen is not 3"
        test "$(cat /proc/sys/net/ipv4/tcp_migrate_req)" = 1 \
          || fail "tcp_migrate_req is not 1"
        install -d -m 0700 "$state_dir"
        rm -f "$state_dir/stop" "$state_dir/status" "$state_dir/count" \
          "$state_dir/evidence" "$state_dir"/.evidence.*
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
          next_operation=$((operations + 1))
          ${pkgs.python3}/bin/python3 ${tcpOperation} \
            "$state_dir/evidence" "$next_operation"
          operations=$next_operation
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
        for _ in $(seq 1 360); do
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
        timeout 90 tail --pid="$pid" -f /dev/null
        ! kill -0 "$pid" 2>/dev/null || fail "workload did not stop"
        test -f "$state_dir/status" || fail "workload status is missing"
        test -f "$state_dir/evidence" || fail "workload evidence is missing"
        grep -Fx 'status=ok' "$state_dir/status" >/dev/null
        cat "$state_dir/status"
        cat "$state_dir/evidence"
        ;;

      cleanup)
        if test -f "$state_dir/pid"; then
          pid=$(cat "$state_dir/pid")
          ! kill -0 "$pid" 2>/dev/null || fail "workload is still running"
        fi
        rm -f "$state_dir/pid" "$state_dir/stop" "$state_dir/status" \
          "$state_dir/count" "$state_dir/evidence" "$state_dir/workload.log" \
          "$state_dir"/.evidence.*
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

    def validate_reqsk_capture_relation(plan_set, captured_set)
      planned_members = plan_set.fetch('members')
      captured_members = captured_set.fetch('members')
      raise 'planned member set is empty' if planned_members.empty?
      raise 'capture member count does not match plan' unless
        captured_members.length == planned_members.length
      raise 'planned set does not start at 6.12.113.1' unless
        planned_members.first.fetch('release') == '6.12.113.1'
      raise 'planned set ID does not match its tip' unless
        plan_set.fetch('id') == planned_members.last.fetch('release')
      raise 'planned tip release does not match its members' unless
        plan_set.fetch('tipRelease') == planned_members.last.fetch('release')

      captured_members.each_with_index do |member, index|
        planned_member = planned_members.fetch(index)
        expected_release = "6.12.113.#{index + 1}"
        expected_predecessor =
          index.zero? ? nil : planned_members.fetch(index - 1).fetch('release')
        raise 'planned member release is not contiguous' unless
          planned_member.fetch('release') == expected_release
        raise 'planned member ordinal is not contiguous' unless
          planned_member.fetch('releaseOrdinal') == index + 1
        raise 'planned member predecessor is inconsistent' unless
          planned_member.fetch('predecessorRelease') == expected_predecessor
        raise 'capture member release does not match plan' unless
          member.fetch('release') == planned_member.fetch('release')
        raise 'planned member target does not match set target' unless
          planned_member.fetch('kernelVersion') == plan_set.fetch('kernelVersion')
      end
    end

    expected_set = JSON.parse(${builtins.toJSON expectedSetJson})
    plan_sets = @plan.fetch('sets').select do |candidate|
      candidate.fetch('id') == ROW.fetch('setId')
    end
    captured_sets = @capture.fetch('sets').select do |candidate|
      candidate.fetch('id') == ROW.fetch('setId')
    end
    expect(plan_sets.length).to eq(1)
    expect(captured_sets.length).to eq(1)
    plan_set = plan_sets.fetch(0)
    captured_set = captured_sets.fetch(0)
    expect(plan_set).to eq(expected_set)
    validate_reqsk_capture_relation(plan_set, captured_set)
    planned_members = plan_set.fetch('members')
    captured_members = captured_set.fetch('members')
    expect(@plan.fetch('counts').fetch('catalogReleases')).to eq(@plan.fetch('releases').length)
    expect(@plan.fetch('counts').fetch('normalizedReleases')).to eq(@plan.fetch('releases').length)
    expect(@plan.fetch('counts').fetch('plannedMembers')).to eq(planned_members.length)
    expect(@plan.fetch('counts').fetch('activeOracles')).to eq(plan_set.fetch('oracleIds').length)
    expect(@plan.fetch('counts').fetch('coverageTuples')).to eq(@plan.fetch('coverage').length)
    expect(@plan.fetch('counts').fetch('plannedRows')).to eq(@plan.fetch('rows').length)
    expect(@plan.fetch('counts').fetch('matrixRows')).to eq(@plan.fetch('matrix').fetch('include').length)
    expect(plan_set.fetch('kernelVersion')).to eq('6.12.113')
    expect(ROW.fetch('scope')).to eq('fix')
    expect(ROW.fetch('role')).to eq('operation-safety')
    expect(ROW.fetch('profileId')).to eq("fix/${fixId}/${oracleId}")
    expect(ROW.fetch('oracleIds')).to eq([${builtins.toJSON oracleId}])
    expect(ROW.fetch('supported')).to eq(true)
    expect(ROW.fetch('platform').fetch('id')).to eq(ROW.fetch('platformId'))
    expect(ROW.fetch('platform').fetch('runnerClass')).to eq(ROW.fetch('runnerClass'))

    expected_vendor = {
      'amd' => 'AuthenticAMD',
      'intel' => 'GenuineIntel',
    }.fetch(ROW.fetch('platformId'))
    vendor = machine.succeeds(
      "awk -F: '/vendor_id/{gsub(/ /, \"\", $2); print $2; exit}' /proc/cpuinfo",
    )[1].strip
    expect(vendor).to eq(expected_vendor)

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

    member_records.each do |member|
      identity = member.fetch(:identity)
      producer = Shellwords.escape(identity.fetch('producer'))
      module_path = member.fetch(:module_path)
      module_name_shell = Shellwords.escape(member.fetch(:module_name))
      evidence = "#{producer}/share/vpsadminos-livepatch"
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

    enable_member = lambda do |member|
      module_path = member.fetch(:module_path)
      module_name = member.fetch(:module_name)
      module_name_shell = Shellwords.escape(module_name)
      patch_dir = member.fetch(:patch_dir)
      machine.succeeds(
        "test ! -e #{Shellwords.escape(patch_dir)} && " \
          "test ! -e /sys/module/#{module_name_shell}",
      )
      machine.succeeds("insmod #{module_path}", timeout: 60)
      machine.wait_until_succeeds(
        "test -d #{Shellwords.escape(patch_dir)} && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/enabled)\" = 1 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/transition)\" = 0 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/replace)\" = 0",
        timeout: 180,
      )
      machine.succeeds(
        "test \"$(uname -r)\" = #{Shellwords.escape(member.fetch(:release))}",
      )
      {
        release: member.fetch(:release),
        enabled: 1,
        transition: 0,
        replace: 0,
      }
    end

    disable_member = lambda do |member, expected_release|
      module_name = member.fetch(:module_name)
      module_name_shell = Shellwords.escape(module_name)
      patch_dir = member.fetch(:patch_dir)
      machine.succeeds(
        "sh -c 'echo 0 > #{Shellwords.escape(patch_dir)}/enabled'",
        timeout: 60,
      )
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && " \
          "test -d /sys/module/#{module_name_shell}",
        timeout: 180,
      )
      machine.succeeds("rmmod #{module_name_shell}", timeout: 60)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && " \
          "test ! -d /sys/module/#{module_name_shell}",
        timeout: 180,
      )
      machine.succeeds(
        "test \"$(uname -r)\" = #{Shellwords.escape(expected_release)}",
      )
      {
        removedRelease: member.fetch(:release),
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

    forward = member_records.map do |member|
      result = enable_member.call(member)
      checkpoints << progress.call(checkpoints.last)
      result
    end

    reverse = member_records.each_index.reverse_each.map do |index|
      member = member_records.fetch(index)
      predecessor_release =
        index.zero? ? '6.12.113' : member_records.fetch(index - 1).fetch(:release)
      result = disable_member.call(member, predecessor_release)
      checkpoints << progress.call(checkpoints.last)
      result
    end

    workload = machine.succeeds('${toolName} stop')[1]
    operations_match = workload.match(/^operations=([0-9]+)$/)
    expect(operations_match).not_to be_nil
    operations = Integer(operations_match[1], 10)
    expect(operations).to be >= checkpoints.last
    evidence_lines = workload.lines.select { |line| line.start_with?('{') }
    expect(evidence_lines.length).to eq(1)
    timer_callback_migration = JSON.parse(evidence_lines.fetch(0))
    expect(timer_callback_migration.fetch('operation')).to eq(operations)
    machine.succeeds('${toolName} cleanup')

    kernel_output = machine.succeeds("dmesg | tail -n +#{dmesg_start + 1}")[1]
    fatal_pattern = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)|KASAN:|KFENCE:|refcount_t:|timer:.*(?:corrupt|invalid)/
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
      identities: captured_members.map { |member| member.fetch('identity') },
      workload: {
        operations: operations,
        checkpoints: checkpoints,
        ordinaryOperation: ${builtins.toJSON operationLabel},
        ipv4: true,
        ipv6: true,
        syncookies: 2,
        fastOpen: true,
        reuseportMigration: true,
        listenerClose: true,
        timerCallbackMigration: timer_callback_migration,
      },
      forward: {
        orderedReleases: forward.map { |entry| entry.fetch(:release) },
        replace: 0,
      },
      reverse: {
        orderedReleases: reverse.map { |entry| entry.fetch(:release) },
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
      { ... }:
      {
        boot.kernel.sysctl = {
          "net.ipv4.tcp_fastopen" = 3;
          "net.ipv4.tcp_migrate_req" = 1;
          "net.ipv4.tcp_syncookies" = 2;
        };
        environment.systemPackages = [
          operationTool
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.kmod
          pkgs.python3
          pkgs.util-linux
        ];
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

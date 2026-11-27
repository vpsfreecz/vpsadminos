{
  capture,
  oracle,
  plan,
  pkgs,
  qualificationSet,
  row,
  profile,
}:

let
  inherit (profile)
    adapterPath
    fixId
    operationKind
    oracleId
    validatorPath
    ;

  ioRunnerSource = pkgs.writeText "${fixId}-io-runner.c" ''
    #include <liburing.h>
    #include <signal.h>
    #include <stdio.h>
    #include <string.h>
    #include <sys/wait.h>
    #include <unistd.h>

    int main(int argc, char **argv)
    {
      struct io_uring ring;
      struct io_uring_cqe *cqe;
      siginfo_t info;
      pid_t child;
      int ret;
      if (argc != 2 || strcmp(argv[1], "io-waitid") != 0)
        return 2;
      ret = io_uring_queue_init(16, &ring, 0);
      if (ret < 0) {
        fprintf(stderr, "io_uring_queue_init: %s\n", strerror(-ret));
        return 1;
      }

      struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);

      child = fork();
      if (child < 0 || sqe == NULL)
        return 1;
      if (child == 0) {
        pause();
        _exit(1);
      }
      memset(&info, 0, sizeof(info));
      io_uring_prep_waitid(sqe, P_PID, child, &info, WEXITED, 0);
      if (io_uring_submit(&ring) != 1 || kill(child, SIGTERM) != 0)
        return 1;
      ret = io_uring_wait_cqe(&ring, &cqe);
      if (ret < 0 || cqe->res != 0 || info.si_pid != child)
        return 1;
      io_uring_cqe_seen(&ring, cqe);

      io_uring_queue_exit(&ring);
      printf("operation=io-waitid completions=1 waitid=ok\n");
      return 0;
    }
  '';

  ioRunner = pkgs.stdenv.mkDerivation {
    pname = "${fixId}-io-runner";
    version = "1";
    dontUnpack = true;
    src = ioRunnerSource;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.liburing ];

    buildPhase = ''
      runHook preBuild
      $CC -std=gnu11 -O2 -Wall -Wextra -Werror "$src" \
        -o core-io-operation $(pkg-config --cflags --libs liburing)
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm0755 core-io-operation $out/bin/core-io-operation
      runHook postInstall
    '';
  };

  coredumpRunnerSource = pkgs.writeText "${fixId}-coredump-runner.c" ''
    #include <pthread.h>
    #include <sched.h>
    #include <signal.h>
    #include <stdatomic.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <sys/wait.h>
    #include <unistd.h>

    static atomic_uint parked;

    static void *park_thread(void *unused)
    {
      (void)unused;
      atomic_fetch_add_explicit(&parked, 1, memory_order_release);
      for (;;)
        pause();
      return NULL;
    }

    int main(void)
    {
      pthread_t threads[4];
      pid_t child = fork();
      int status;

      if (child < 0)
        return 1;
      if (child == 0) {
        for (unsigned int i = 0; i < 4; i++)
          if (pthread_create(&threads[i], NULL, park_thread, NULL) != 0)
            _exit(1);
        while (atomic_load_explicit(&parked, memory_order_acquire) != 4)
          sched_yield();
        abort();
      }

      if (waitpid(child, &status, 0) != child)
        return 1;
      if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGABRT)
        return 1;
      puts("threads=4 signal=SIGABRT");
      return 0;
    }
  '';

  coredumpRunner = pkgs.stdenv.mkDerivation {
    pname = "${fixId}-coredump-runner";
    version = "1";
    dontUnpack = true;
    src = coredumpRunnerSource;

    buildPhase = ''
      runHook preBuild
      $CC -std=gnu11 -O2 -Wall -Wextra -Werror -pthread "$src" \
        -o core-coredump-operation
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm0755 core-coredump-operation $out/bin/core-coredump-operation
      runHook postInstall
    '';
  };

  operationTool = pkgs.writeShellScriptBin "${fixId}-operation" ''
    set -euo pipefail

    state_dir=/run/${fixId}-operation
    operation_kind=${operationKind}

    fail() {
      echo "${fixId}-operation: $*" >&2
      exit 1
    }

    run_mount_operation() {
      kind=$1
      root=$(${pkgs.coreutils}/bin/mktemp -d /run/core-mount-operation.XXXXXX)
      cleanup_mount_root() {
        ${pkgs.coreutils}/bin/rm -rf -- "$root"
      }
      trap cleanup_mount_root EXIT HUP INT TERM
      unshare --mount --fork sh -eu -c '
        kind=$1
        root=$2
        mount --make-rprivate /
        case "$kind" in
          pivot-root)
            mount --bind / "$root"
            mkdir -p "$root/old-root"
            mount --bind /nix/store "$root/nix/store"
            mount --bind /proc "$root/proc"
            cd "$root"
            pivot_root . old-root
            cd /
            test -r /proc/self/status
            ${pkgs.util-linux}/bin/umount -l /old-root
            ;;
          *) exit 2 ;;
        esac
      ' sh "$kind" "$root"
      trap - EXIT HUP INT TERM
      cleanup_mount_root
    }

    run_key_operation() {
      session=$(keyctl new_session core-livepatch)
      key=$(printf ordinary | keyctl padd user core-livepatch-key "$session")
      keyctl search "$session" user core-livepatch-key >/dev/null
      keyctl pipe "$key" | grep -Fx ordinary >/dev/null
      test "$operation_kind" = request-key || fail "unsupported key operation: $operation_kind"
      requested=$(keyctl request2 user core-livepatch-key ordinary "$session")
      test "$requested" = "$key"
      keyctl unlink "$key" "$session"
      keyctl clear "$session"
    }

    run_pidns_reaper_operation() {
      result=$(mktemp -d "$state_dir/pidns-freezer.XXXXXX")
      mkfifo "$result/release"

      timeout --kill-after=1 15 unshare --pid --fork --mount-proc sh -eu -c '
        result=$1
        test "$$" -eq 1
        for name in one two three; do
          (
            trap "" HUP INT TERM
            exec sleep 3600
          ) &
          child=$!
          kill -0 "$child"
        done
        printf "ready\n" > "$result/ready"
        IFS= read -r release < "$result/release"
        test "$release" = release
        exit 0
      ' sh "$result" &
      timeout_pid=$!

      abort_pidns_fixture() {
        message=$1
        printf "release\n" > "$result/release"
        wait "$timeout_pid" 2>/dev/null || true
        rm -rf -- "$result"
        fail "$message"
      }

      attempts=0
      while test ! -e "$result/ready" && test "$attempts" -lt 500; do
        attempts=$((attempts + 1))
        sleep 0.02
      done
      if test ! -e "$result/ready"; then
        wait "$timeout_pid" 2>/dev/null || true
        rm -rf -- "$result"
        fail "PID namespace fixture did not become ready within its bound"
      fi

      grep -Fx ready "$result/ready" >/dev/null

      timeout_children=$(cat "/proc/$timeout_pid/task/$timeout_pid/children")
      set -- $timeout_children
      test "$#" -eq 1 || abort_pidns_fixture \
        "PID namespace timeout wrapper has an unexpected process tree"
      unshare_pid=$1

      unshare_children=$(cat "/proc/$unshare_pid/task/$unshare_pid/children")
      set -- $unshare_children
      test "$#" -eq 1 || abort_pidns_fixture \
        "PID namespace launcher has an unexpected process tree"
      init_pid=$1
      init_start=$(awk '{print $22}' "/proc/$init_pid/stat")
      case "$init_pid:$init_start" in
        *[!0-9:]*|:*)
          abort_pidns_fixture "PID namespace init identity is invalid"
          ;;
      esac

      init_children=$(cat "/proc/$init_pid/task/$init_pid/children")
      set -- $init_children
      test "$#" -eq 3 || abort_pidns_fixture \
        "PID namespace live-descendant inventory is incomplete"
      : > "$result/descendants"
      for host_pid in "$@"; do
        start_time=$(awk '{print $22}' "/proc/$host_pid/stat")
        case "$host_pid:$start_time" in
          *[!0-9:]*|:*)
            abort_pidns_fixture \
              "PID namespace descendant identity is invalid"
            ;;
        esac
        printf "%s %s\n" "$host_pid" "$start_time" \
          >> "$result/descendants"
      done

      printf "release\n" > "$result/release"
      if ! wait "$timeout_pid"; then
        rm -rf -- "$result"
        fail "PID namespace reaper did not complete within its bound"
      fi

      if test -r "/proc/$init_pid/stat"; then
        current_start=$(awk '{print $22}' "/proc/$init_pid/stat")
        test "$current_start" != "$init_start" || {
          rm -rf -- "$result"
          fail "PID namespace init survived reaper completion"
        }
      fi
      while read -r host_pid start_time; do
        if test -r "/proc/$host_pid/stat"; then
          current_start=$(awk '{print $22}' "/proc/$host_pid/stat")
          test "$current_start" != "$start_time" || {
            rm -rf -- "$result"
            fail "PID namespace descendant survived reaper completion"
          }
        fi
      done < "$result/descendants"

      printf "descendants=3 reaper=completed\n"
      rm -rf -- "$result"
    }

    run_once() {
      case "$operation_kind" in
        pivot-root)
          run_mount_operation "$operation_kind"
          ;;
        request-key)
          run_key_operation
          ;;
        coredump)
          ulimit -c 0
          core-coredump-operation >/dev/null
          ;;
        pidns-freezer)
          run_pidns_reaper_operation
          ;;
        io-waitid)
          core-io-operation "$operation_kind" >/dev/null
          ;;
        *)
          fail "unsupported operation kind: $operation_kind"
          ;;
      esac
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
        install -d -m 0700 "$state_dir"
        test ! -e "$state_dir/pid" || fail "workload pid already exists"
        test ! -e "$state_dir/status" || fail "workload status already exists"
        test ! -e "$state_dir/stop" || fail "workload stop already exists"
        run_once
        ;;
      start)
        test -d "$state_dir" || fail "state directory is missing"
        nohup "$0" worker > "$state_dir/workload.log" 2>&1 < /dev/null &
        pid=$!
        printf '%s\n' "$pid" > "$state_dir/pid"
        kill -0 "$pid"
        ;;
      worker)
        operations=0
        while test ! -e "$state_dir/stop"; do
          run_once
          operations=$((operations + 1))
          if test "$operations" -ge 20000; then
            write_status exhausted "$operations"
            exit 1
          fi
          sleep 0.02
        done
        write_status ok "$operations"
        ;;
      operate)
        run_once
        ;;
      stop)
        pid=$(cat "$state_dir/pid")
        [[ "$pid" =~ ^[0-9]+$ ]] || fail "invalid workload pid"
        kill -0 "$pid" || fail "workload is not running"
        : > "$state_dir/stop"
        timeout 30 tail --pid="$pid" -f /dev/null
        ! kill -0 "$pid" 2>/dev/null || fail "workload did not stop"
        grep -Fx 'status=ok' "$state_dir/status" >/dev/null
        cat "$state_dir/status"
        ;;
      cleanup)
        pid=$(cat "$state_dir/pid")
        ! kill -0 "$pid" 2>/dev/null || fail "workload is still running"
        grep -Fx 'status=ok' "$state_dir/status" >/dev/null
        ;;
      *)
        fail "unsupported command: $command"
        ;;
    esac
  '';

  expectedSetJson = builtins.toJSON qualificationSet;
  fixIdJson = builtins.toJSON fixId;
  oracleIdJson = builtins.toJSON oracleId;
  operationKindJson = builtins.toJSON operationKind;
  adapterPathJson = builtins.toJSON adapterPath;
  validatorPathJson = builtins.toJSON validatorPath;
  operationCommandJson = builtins.toJSON "${fixId}-operation";

  oracleScript = ''
    require 'json'
    require 'shellwords'

    FIX_ID = ${fixIdJson}
    ORACLE_ID = ${oracleIdJson}
    OPERATION_KIND = ${operationKindJson}
    ADAPTER_PATH = ${adapterPathJson}
    VALIDATOR_PATH = ${validatorPathJson}
    OPERATION_COMMAND = ${operationCommandJson}

    def validate_core_capture_relation(plan_set, captured_set)
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

    def wait_core_enabled(machine, patch_dir)
      machine.wait_until_succeeds(
        "test -d #{Shellwords.escape(patch_dir)} && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/enabled)\" = 1 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/transition)\" = 0 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/replace)\" = 0",
        timeout: 180,
      )
    end

    def wait_core_disabled(machine, patch_dir, module_name)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && " \
          "test -d /sys/module/#{Shellwords.escape(module_name)}",
        timeout: 180,
      )
    end

    def wait_core_module_removed(machine, module_name)
      machine.wait_until_succeeds(
        "test ! -d /sys/module/#{Shellwords.escape(module_name)}",
        timeout: 180,
      )
    end

    def enable_core_member(machine, member)
      machine.succeeds("insmod #{member.fetch(:module_path)}", timeout: 60)
      wait_core_enabled(machine, member.fetch(:patch_dir))
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(member.fetch(:release))}")
      {
        release: member.fetch(:release),
        enabled: 1,
        transition: 0,
        replace: 0,
      }
    end

    def disable_core_member(machine, members, index, native_release)
      member = members.fetch(index)
      predecessor_release = index.zero? ? native_release : members.fetch(index - 1).fetch(:release)
      patch_dir = member.fetch(:patch_dir)
      module_name = member.fetch(:module_name)
      machine.succeeds("sh -c 'echo 0 > #{Shellwords.escape(patch_dir)}/enabled'", timeout: 60)
      wait_core_disabled(machine, patch_dir, module_name)
      machine.succeeds("rmmod #{Shellwords.escape(module_name)}", timeout: 60)
      wait_core_module_removed(machine, module_name)
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(predecessor_release)}")
      {
        removedRelease: member.fetch(:release),
        release: predecessor_release,
        moduleRemoved: true,
      }
    end

    expected_set = JSON.parse(${builtins.toJSON expectedSetJson})
    plan_set = @plan.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }.fetch(0)
    captured_set = @capture.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }.fetch(0)
    expect(plan_set).to eq(expected_set)
    validate_core_capture_relation(plan_set, captured_set)
    expect(ROW.fetch('scope')).to eq('fix')
    expect(ROW.fetch('role')).to eq('operation-safety')
    expect(ROW.fetch('oracleIds')).to eq([ORACLE_ID])
    expect(ROW.fetch('profileId')).to eq("fix/#{FIX_ID}/#{ORACLE_ID}")
    expect(ROW.fetch('testAdapter')).to eq(ADAPTER_PATH)
    expect(ROW.fetch('validator')).to eq(VALIDATOR_PATH)

    expected_vendor = {
      'amd' => 'AuthenticAMD',
      'intel' => 'GenuineIntel',
    }.fetch(ROW.fetch('platformId'))
    vendor = machine.succeeds("awk -F: '/vendor_id/{gsub(/ /, \"\", $2); print $2; exit}' /proc/cpuinfo")[1].strip
    expect(vendor).to eq(expected_vendor)

    captured_members = captured_set.fetch('members')
    members = captured_members.each_with_index.map do |member, index|
      expect(member.fetch('release')).to eq(plan_set.fetch('members').fetch(index).fetch('release'))
      identity = member.fetch('identity')
      expect(identity.keys.sort).to eq(%w[
        closureSha256 flakeLockSha256 inputDigest inspectionSha256 manifestSha256
        module moduleName moduleSha256 producer sourceRevision targetId vermagic
      ].sort)
      producer = Shellwords.escape(identity.fetch('producer'))
      module_path = Shellwords.escape(identity.fetch('module'))
      module_name = identity.fetch('moduleName')
      module_name_shell = Shellwords.escape(module_name)
      evidence = "#{producer}/share/vpsadminos-livepatch"
      machine.all_succeed(
        "test -f #{module_path}",
        "test \"$(sha256sum #{module_path} | cut -d' ' -f1)\" = #{identity.fetch('moduleSha256')}",
        "test \"$(sha256sum #{evidence}/manifest.json | cut -d' ' -f1)\" = #{identity.fetch('manifestSha256')}",
        "test \"$(sha256sum #{evidence}/inspection.json | cut -d' ' -f1)\" = #{identity.fetch('inspectionSha256')}",
        "test \"$(sha256sum #{evidence}/closure.json | cut -d' ' -f1)\" = #{identity.fetch('closureSha256')}",
        "jq -e '.matches == true and .mismatches == {}' #{evidence}/closure.json",
        "jq -e --arg name #{module_name_shell} '.module.name == $name and .buildInvocation.nonReplaceRequested == true' #{evidence}/inspection.json",
        "test ! -e /sys/kernel/livepatch/#{module_name_shell}",
      )
      {
        release: member.fetch('release'),
        identity: identity,
        module_path: module_path,
        module_name: module_name,
        patch_dir: "/sys/kernel/livepatch/#{module_name}",
      }
    end

    machine.succeeds('test "$(uname -r)" = 6.12.113')
    dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i
    forward = [enable_core_member(machine, members.fetch(0))]
    machine.succeeds("#{OPERATION_COMMAND} prepare")
    machine.succeeds("#{OPERATION_COMMAND} start")
    machine.succeeds("#{OPERATION_COMMAND} operate")

    members.drop(1).each do |member|
      forward << enable_core_member(machine, member)
      machine.succeeds("#{OPERATION_COMMAND} operate")
    end

    reverse = members.each_index.reverse_each.map do |index|
      boundary = disable_core_member(machine, members, index, '6.12.113')
      machine.succeeds("#{OPERATION_COMMAND} operate")
      boundary
    end

    workload = machine.succeeds("#{OPERATION_COMMAND} stop")[1]
    operations = Integer(workload.match(/^operations=([0-9]+)$/)[1], 10)
    expect(operations).to be > 0
    machine.succeeds("#{OPERATION_COMMAND} cleanup")

    kernel_output = machine.succeeds("dmesg | tail -n +#{dmesg_start + 1}")[1]
    fatal_pattern = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)/
    expect(kernel_output).not_to match(fatal_pattern)

    marker = {
      schemaVersion: 1,
      fixId: FIX_ID,
      oracleId: ORACLE_ID,
      operationKind: OPERATION_KIND,
      platformId: ROW.fetch('platformId'),
      runnerClass: ROW.fetch('runnerClass'),
      rowId: ROW.fetch('rowId'),
      setId: ROW.fetch('setId'),
      release: plan_set.fetch('tipRelease'),
      nativeRelease: '6.12.113',
      memberReleases: captured_members.map { |member| member.fetch('release') },
      members: captured_members.map { |member| member.fetch('identity') },
      workload: { operations: operations },
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
      cleanup: { release: '6.12.113', predecessorModuleRemoved: true },
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
        environment.systemPackages = [
          coredumpRunner
          operationTool
          ioRunner
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.keyutils
          pkgs.kmod
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

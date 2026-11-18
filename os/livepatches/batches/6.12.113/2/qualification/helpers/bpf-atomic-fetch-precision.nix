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
        fixId = "bpf-atomic-fetch-precision";
        oracleId = "bpf-atomic-fetch-precision-operation-safety";
        programName = "bpf_atomic_fetch_precision";
        adapterPath = "os/livepatches/batches/6.12.113/2/qualification/helpers/bpf-atomic-fetch-precision.nix";
        validatorPath = "os/livepatches/batches/6.12.113/2/qualification/validators/bpf-atomic-fetch-precision.sh";
        bpfSource = ''
          // SPDX-License-Identifier: GPL-2.0
          #include <linux/bpf.h>
          #include <bpf/bpf_helpers.h>

          SEC("socket")
          __attribute__((naked))
          int bpf_atomic_fetch_precision(void)
          {
            asm volatile (
              "r1 = 8;"
              "*(u64 *)(r10 - 8) = r1;"
              "r2 = 0;"
              ".8byte 0x00000001fff82adb;"
              "r3 = r10;"
              "r3 += r2;"
              "r0 = 64;"
              "exit;"
            );
          }

          char LICENSE[] SEC("license") = "GPL";
        '';
      }
    else
      profile;

  inherit (effectiveProfile)
    adapterPath
    bpfSource
    fixId
    oracleId
    programName
    validatorPath
    ;

  bpfSourceFile = pkgs.writeText "${fixId}.bpf.c" bpfSource;

  bpfObject = pkgs.stdenv.mkDerivation {
    pname = "${fixId}-bpf-object";
    version = "1";
    dontUnpack = true;
    hardeningDisable = [ "all" ];
    nativeBuildInputs = [ pkgs.llvmPackages.clang-unwrapped ];

    buildPhase = ''
      runHook preBuild
      ${pkgs.llvmPackages.clang-unwrapped}/bin/clang \
        -std=gnu11 \
        -Werror \
        -Wno-compare-distinct-pointer-types \
        -fno-stack-protector \
        -O2 \
        -g \
        -target bpf \
        -D__x86_64__ \
        -D__TARGET_ARCH_x86 \
        -idirafter ${pkgs.linuxHeaders}/include \
        -idirafter ${pkgs.libbpf}/include \
        -c ${bpfSourceFile} \
        -o ${programName}.bpf.o
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm0644 ${programName}.bpf.o $out/${programName}.bpf.o
      runHook postInstall
    '';
  };

  runnerSource = pkgs.writeText "${fixId}-runner.c" ''
    #include <errno.h>
    #include <linux/bpf.h>
    #include <stdbool.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/resource.h>
    #include <sys/socket.h>
    #include <sys/time.h>
    #include <unistd.h>

    #include <bpf/bpf.h>
    #include <bpf/libbpf.h>

    #define BPF_OBJECT_PATH "${bpfObject}/${programName}.bpf.o"
    #define BPF_PROGRAM_NAME "${programName}"
    #define EXPECTED_RETVAL 64U

    static int fail_errno(const char *operation, int error)
    {
      int positive = error < 0 ? -error : error;

      fprintf(stderr, "%s: %s\n", operation, strerror(positive));
      return 1;
    }

    int main(void)
    {
      struct bpf_test_run_opts test_opts = {
        .sz = sizeof(test_opts),
      };
      struct bpf_object *object = NULL;
      struct bpf_program *program;
      struct rlimit memlock = {
        .rlim_cur = RLIM_INFINITY,
        .rlim_max = RLIM_INFINITY,
      };
      struct timeval timeout = {
        .tv_sec = 2,
      };
      unsigned char input[64];
      unsigned char output[64];
      unsigned char received[64];
      int sockets[2] = { -1, -1 };
      int program_fd;
      int error;
      ssize_t count;
      int result = 1;

      memset(input, 0x2a, sizeof(input));
      memset(output, 0, sizeof(output));
      memset(received, 0, sizeof(received));

      if (setrlimit(RLIMIT_MEMLOCK, &memlock) != 0 && errno != EPERM)
        return fail_errno("setrlimit", errno);

      libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
      libbpf_set_print(NULL);
      object = bpf_object__open_file(BPF_OBJECT_PATH, NULL);
      error = libbpf_get_error(object);
      if (error) {
        object = NULL;
        result = fail_errno("bpf_object__open_file", error);
        goto out;
      }

      program = bpf_object__find_program_by_name(object, BPF_PROGRAM_NAME);
      if (program == NULL) {
        fprintf(stderr, "program %s is missing\n", BPF_PROGRAM_NAME);
        goto out;
      }

      error = bpf_object__load(object);
      if (error) {
        result = fail_errno("bpf_object__load", error);
        goto out;
      }
      program_fd = bpf_program__fd(program);
      if (program_fd < 0) {
        result = fail_errno("bpf_program__fd", program_fd);
        goto out;
      }

      test_opts.data_in = input;
      test_opts.data_size_in = sizeof(input);
      test_opts.data_out = output;
      test_opts.data_size_out = sizeof(output);
      test_opts.repeat = 1;
      error = bpf_prog_test_run_opts(program_fd, &test_opts);
      if (error) {
        result = fail_errno("bpf_prog_test_run_opts", error);
        goto out;
      }
      if (test_opts.retval != EXPECTED_RETVAL ||
          test_opts.data_size_out != sizeof(input) ||
          memcmp(output, input, sizeof(input)) != 0) {
        fprintf(stderr, "unexpected test result: retval=%u bytes=%u\n",
                test_opts.retval, test_opts.data_size_out);
        goto out;
      }

      if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0, sockets) != 0) {
        result = fail_errno("socketpair", errno);
        goto out;
      }
      if (setsockopt(sockets[1], SOL_SOCKET, SO_RCVTIMEO,
                     &timeout, sizeof(timeout)) != 0) {
        result = fail_errno("SO_RCVTIMEO", errno);
        goto out;
      }
      if (setsockopt(sockets[1], SOL_SOCKET, SO_ATTACH_BPF,
                     &program_fd, sizeof(program_fd)) != 0) {
        result = fail_errno("SO_ATTACH_BPF", errno);
        goto out;
      }

      count = send(sockets[0], input, sizeof(input), 0);
      if (count != (ssize_t)sizeof(input)) {
        result = fail_errno("send", count < 0 ? errno : EIO);
        goto out;
      }
      count = recv(sockets[1], received, sizeof(received), 0);
      if (count != (ssize_t)sizeof(input) ||
          memcmp(received, input, sizeof(input)) != 0) {
        result = fail_errno("filtered packet receive", count < 0 ? errno : EIO);
        goto out;
      }

      printf("result=ok retval=%u test-bytes=%u socket-bytes=%zd\n",
             test_opts.retval, test_opts.data_size_out, count);
      result = 0;

    out:
      if (sockets[0] >= 0)
        close(sockets[0]);
      if (sockets[1] >= 0)
        close(sockets[1]);
      bpf_object__close(object);
      return result;
    }
  '';

  operationRunner = pkgs.stdenv.mkDerivation {
    pname = "${fixId}-runner";
    version = "1";
    dontUnpack = true;
    src = runnerSource;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [
      pkgs.elfutils
      pkgs.libbpf
      pkgs.zlib
    ];

    buildPhase = ''
      runHook preBuild
      $CC -std=gnu11 -O2 -Wall -Wextra -Werror \
        "$src" \
        -o bpf-operation-runner \
        $(pkg-config --cflags --libs libbpf)
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm0755 bpf-operation-runner $out/bin/bpf-operation-runner
      runHook postInstall
    '';
  };

  operationTool = pkgs.writeShellScriptBin "${fixId}-operation" ''
    set -euo pipefail

    state_dir=/run/${fixId}-operation
    runner=${operationRunner}/bin/bpf-operation-runner

    fail() {
      echo "${fixId}-operation: $*" >&2
      exit 1
    }

    run_once() {
      output=$($runner)
      grep -Fx 'result=ok retval=64 test-bytes=64 socket-bytes=64' <<<"$output" >/dev/null \
        || fail "unexpected runner output: $output"
      printf '%s\n' "$output"
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
          ${pkgs.coreutils}/bin/sleep 0.01
        done
        write_status ok "$operations"
        ;;

      operate)
        test -d "$state_dir" || fail "state directory is missing"
        run_once
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
  adapterPathJson = builtins.toJSON adapterPath;
  validatorPathJson = builtins.toJSON validatorPath;
  operationCommandJson = builtins.toJSON "${fixId}-operation";

  oracleScript = ''
    require 'json'
    require 'shellwords'

    FIX_ID = ${fixIdJson}
    ORACLE_ID = ${oracleIdJson}
    ADAPTER_PATH = ${adapterPathJson}
    VALIDATOR_PATH = ${validatorPathJson}
    OPERATION_COMMAND = ${operationCommandJson}

    def validate_bpf_capture_relation(plan_set, captured_set)
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

    def wait_bpf_enabled(machine, patch_dir)
      machine.wait_until_succeeds(
        "test -d #{Shellwords.escape(patch_dir)} && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/enabled)\" = 1 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/transition)\" = 0 && " \
          "test \"$(cat #{Shellwords.escape(patch_dir)}/replace)\" = 0",
        timeout: 180,
      )
    end

    def wait_bpf_disabled(machine, patch_dir, module_name)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && " \
          "test -d /sys/module/#{Shellwords.escape(module_name)}",
        timeout: 180,
      )
    end

    def enable_bpf_member(machine, member)
      machine.succeeds("insmod #{member.fetch(:module_path)}", timeout: 60)
      wait_bpf_enabled(machine, member.fetch(:patch_dir))
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(member.fetch(:release))}")
      {
        release: member.fetch(:release),
        enabled: 1,
        transition: 0,
        replace: 0,
      }
    end

    def disable_bpf_member(machine, members, index, native_release)
      member = members.fetch(index)
      predecessor_release = index.zero? ? native_release : members.fetch(index - 1).fetch(:release)
      patch_dir = member.fetch(:patch_dir)
      module_name = member.fetch(:module_name)
      module_name_shell = Shellwords.escape(module_name)
      machine.succeeds("sh -c 'echo 0 > #{Shellwords.escape(patch_dir)}/enabled'", timeout: 60)
      wait_bpf_disabled(machine, patch_dir, module_name)
      machine.succeeds("rmmod #{module_name_shell}", timeout: 60)
      machine.wait_until_succeeds(
        "test ! -d #{Shellwords.escape(patch_dir)} && test ! -d /sys/module/#{module_name_shell}",
        timeout: 180,
      )
      machine.succeeds("test \"$(uname -r)\" = #{Shellwords.escape(predecessor_release)}")
      {
        removedRelease: member.fetch(:release),
        release: predecessor_release,
        moduleRemoved: true,
      }
    end

    expected_set = JSON.parse(${builtins.toJSON expectedSetJson})
    plan_sets = @plan.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }
    captured_sets = @capture.fetch('sets').select { |candidate| candidate.fetch('id') == ROW.fetch('setId') }
    expect(plan_sets.length).to eq(1)
    expect(captured_sets.length).to eq(1)
    plan_set = plan_sets.fetch(0)
    captured_set = captured_sets.fetch(0)
    expect(plan_set).to eq(expected_set)
    validate_bpf_capture_relation(plan_set, captured_set)

    expect(ROW.fetch('scope')).to eq('fix')
    expect(ROW.fetch('role')).to eq('operation-safety')
    expect(ROW.fetch('oracleIds')).to eq([ORACLE_ID])
    expect(ROW.fetch('profileId')).to eq("fix/#{FIX_ID}/#{ORACLE_ID}")
    expect(ROW.fetch('testAdapter')).to eq(ADAPTER_PATH)
    expect(ROW.fetch('validator')).to eq(VALIDATOR_PATH)
    expect(ROW.fetch('platform').fetch('id')).to eq(ROW.fetch('platformId'))
    expect(ROW.fetch('platform').fetch('runnerClass')).to eq(ROW.fetch('runnerClass'))
    expect(ROW.fetch('supported')).to eq(true)

    expected_vendor = {
      'amd' => 'AuthenticAMD',
      'intel' => 'GenuineIntel',
    }.fetch(ROW.fetch('platformId'))
    vendor = machine.succeeds("awk -F: '/vendor_id/{gsub(/ /, \"\", $2); print $2; exit}' /proc/cpuinfo")[1].strip
    expect(vendor).to eq(expected_vendor)

    captured_members = captured_set.fetch('members')
    members = captured_members.each_with_index.map do |member, index|
      planned_member = plan_set.fetch('members').fetch(index)
      expect(member.fetch('release')).to eq(planned_member.fetch('release'))
      expect(planned_member.fetch('kernelVersion')).to eq(plan_set.fetch('kernelVersion'))
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
      {
        release: member.fetch('release'),
        identity: identity,
        module_path: module_path,
        module_name: identity.fetch('moduleName'),
        patch_dir: "/sys/kernel/livepatch/#{identity.fetch('moduleName')}",
      }
    end

    target_identity = members.fetch(1).fetch(:identity)

    machine.succeeds('test "$(uname -r)" = 6.12.113')
    dmesg_start = machine.succeeds('dmesg | wc -l')[1].to_i

    forward = [enable_bpf_member(machine, members.fetch(0))]

    prepare = machine.succeeds("#{OPERATION_COMMAND} prepare")[1]
    expect(prepare).to include('result=ok retval=64 test-bytes=64 socket-bytes=64')
    machine.succeeds("#{OPERATION_COMMAND} start")
    machine.succeeds("#{OPERATION_COMMAND} operate")

    members.drop(1).each do |member|
      forward << enable_bpf_member(machine, member)
      machine.succeeds("#{OPERATION_COMMAND} operate")
    end

    reverse = members.each_index.reverse_each.map do |index|
      boundary = disable_bpf_member(machine, members, index, '6.12.113')
      machine.succeeds("#{OPERATION_COMMAND} operate")
      boundary
    end

    workload = machine.succeeds("#{OPERATION_COMMAND} stop")[1]
    operations_match = workload.match(/^operations=([0-9]+)$/)
    expect(operations_match).not_to be_nil
    operations = Integer(operations_match[1], 10)
    expect(operations).to be > 0
    machine.succeeds("#{OPERATION_COMMAND} cleanup")

    kernel_output = machine.succeeds("dmesg | tail -n +#{dmesg_start + 1}")[1]
    fatal_pattern = /BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|(?:rcu|RCU).*stall|livepatch.*(?:error|failed)|BPF:.*(?:fatal|error)/
    expect(kernel_output).not_to match(fatal_pattern)

    marker = {
      schemaVersion: 1,
      fixId: FIX_ID,
      oracleId: ORACLE_ID,
      platformId: ROW.fetch('platformId'),
      runnerClass: ROW.fetch('runnerClass'),
      rowId: ROW.fetch('rowId'),
      setId: ROW.fetch('setId'),
      release: plan_set.fetch('tipRelease'),
      nativeRelease: '6.12.113',
      identity: target_identity,
      memberReleases: captured_members.map { |member| member.fetch('release') },
      members: captured_members.map { |member| member.fetch('identity') },
      workload: {
        backgroundOperations: operations,
        serialOperations: 1 + (2 * members.length),
        verifierLoads: operations + 1 + (2 * members.length),
        testRuns: operations + 1 + (2 * members.length),
        socketPackets: operations + 1 + (2 * members.length),
      },
      stack: {
        predecessorRelease: '6.12.113.1',
        predecessorPresentDuringReverse: true,
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
      cleanup: {
        predecessorModuleRemoved: true,
        release: '6.12.113',
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
        environment.systemPackages = [
          operationTool
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.jq
          pkgs.kmod
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

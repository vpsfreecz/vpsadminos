import ../../make-test.nix (
  {
    pkgs,
    expectReproduce ? false,
  }:
  let
    baseMachine = import ../../machines/vpsadminos/tank.nix pkgs;
    testName =
      if expectReproduce then "zfs-fallocate-deadlock-reproducer" else "zfs-fallocate-deadlock";
    expectReproduceRuby = if expectReproduce then "true" else "false";

    reproducer = pkgs.writeScript "fallocate-deadlock-reproducer.py" ''
      #!${pkgs.python3}/bin/python3

      import ctypes
      import mmap
      import os
      import select
      import signal
      import subprocess
      import sys
      import time

      DATASET = "tank/fallocate-deadlock"
      SNAPSHOT = DATASET + "@filled"
      ROOT = "/zfs-fallocate-deadlock"
      FILE = ROOT + "/victim.bin"

      SIZE_MB = int(os.environ.get("ZFS_FALLOCATE_DEADLOCK_SIZE_MB", "512"))
      SIZE = SIZE_MB * 1024 * 1024
      ATTEMPTS = int(os.environ.get("ZFS_FALLOCATE_DEADLOCK_ATTEMPTS", "4"))
      READERS = int(os.environ.get("ZFS_FALLOCATE_DEADLOCK_READERS", "24"))
      RELEASE_DELAYS_MS = os.environ.get(
          "ZFS_FALLOCATE_DEADLOCK_RELEASE_DELAYS_MS",
          "0,1,2,5,10,20,50,100,250,500",
      )
      READS_PER_LOOP = int(os.environ.get("ZFS_FALLOCATE_DEADLOCK_READS_PER_LOOP", "128"))
      READER_SPAN_PAGES = int(os.environ.get("ZFS_FALLOCATE_DEADLOCK_READER_SPAN_PAGES", "16384"))
      ATTEMPT_TIMEOUT = int(os.environ.get("ZFS_FALLOCATE_DEADLOCK_ATTEMPT_TIMEOUT", "120"))
      STABLE_SECONDS = int(os.environ.get("ZFS_FALLOCATE_DEADLOCK_STABLE_SECONDS", "5"))
      READER_READY_TIMEOUT = int(os.environ.get("ZFS_FALLOCATE_DEADLOCK_READER_READY_TIMEOUT", "30"))
      KILL_WAIT_SECONDS = float(os.environ.get("ZFS_FALLOCATE_DEADLOCK_KILL_WAIT_SECONDS", "5"))

      OUTCOME_REPRODUCED = "reproduced"
      OUTCOME_COMPLETED = "completed"
      OUTCOME_READER_SETUP_FAILED = "reader-setup-failed"
      OUTCOME_EARLY_EXIT = "puncher-exited-before-reader-release"
      OUTCOME_PUNCHER_ERROR = "puncher-error"
      OUTCOME_TIMEOUT = "attempt-timeout"
      TERMINAL_OUTCOMES = (
          OUTCOME_REPRODUCED,
          OUTCOME_COMPLETED,
          OUTCOME_READER_SETUP_FAILED,
          OUTCOME_EARLY_EXIT,
          OUTCOME_PUNCHER_ERROR,
          OUTCOME_TIMEOUT,
      )

      FALLOC_FL_KEEP_SIZE = 0x01
      FALLOC_FL_PUNCH_HOLE = 0x02
      POSIX_FADV_DONTNEED = 4

      libc = ctypes.CDLL("libc.so.6", use_errno=True)
      libc.fallocate.argtypes = [
          ctypes.c_int,
          ctypes.c_int,
          ctypes.c_longlong,
          ctypes.c_longlong,
      ]
      libc.fallocate.restype = ctypes.c_int
      libc.posix_fadvise.argtypes = [
          ctypes.c_int,
          ctypes.c_longlong,
          ctypes.c_longlong,
          ctypes.c_int,
      ]
      libc.posix_fadvise.restype = ctypes.c_int


      def log(message):
          print(message, flush=True)


      def parse_release_delays():
          delays = []
          for item in RELEASE_DELAYS_MS.split(","):
              item = item.strip()
              if item:
                  delays.append(float(item) / 1000.0)

          if not delays:
              delays.append(0.0)

          return delays


      RELEASE_DELAYS = parse_release_delays()


      def run(cmd, check=True):
          log("RUN " + " ".join(cmd))
          return subprocess.run(cmd, check=check)


      def write_param(name, value):
          path = "/sys/module/zfs/parameters/" + name
          if not os.path.exists(path):
              log("PARAM_MISSING " + name)
              return

          try:
              with open(path, "w") as f:
                  f.write(str(value) + "\n")
              log("PARAM_SET %s=%s" % (name, value))
          except OSError as e:
              log("PARAM_SET_FAILED %s=%s errno=%d" % (name, value, e.errno))


      def setup_dataset():
          run(["zfs", "destroy", "-r", DATASET], check=False)
          run([
              "zfs",
              "create",
              "-o",
              "mountpoint=" + ROOT,
              "-o",
              "compression=off",
              "-o",
              "recordsize=4K",
              "-o",
              "primarycache=all",
              "-o",
              "atime=off",
              DATASET,
          ])


      def tune_vm():
          write_param("zfs_delay_min_dirty_percent", 0)
          with open("/proc/sys/kernel/hung_task_timeout_secs", "w") as f:
              f.write("20\n")


      def tune_zfs_for_fill():
          write_param("zfs_dirty_data_max", 64 * 1024 * 1024)
          write_param("zfs_per_txg_dirty_frees_percent", 30)
          write_param("zfs_txg_timeout", 5)


      def tune_zfs_for_free():
          write_param("zfs_dirty_data_max", 4 * 1024 * 1024)
          write_param("zfs_per_txg_dirty_frees_percent", 1)
          write_param("zfs_txg_timeout", 30)


      def fill_file(attempt):
          buf = bytearray(1024 * 1024)
          for i in range(len(buf)):
              buf[i] = (i * 131 + attempt) & 0xff

          fd = os.open(FILE, os.O_CREAT | os.O_TRUNC | os.O_RDWR, 0o644)
          try:
              remaining = SIZE
              while remaining > 0:
                  chunk = buf if remaining >= len(buf) else buf[:remaining]
                  os.write(fd, chunk)
                  remaining -= len(chunk)
              os.fsync(fd)
              libc.posix_fadvise(fd, 0, SIZE, POSIX_FADV_DONTNEED)
          finally:
              os.close(fd)

          subprocess.run(["sync"], check=False)
          try:
              with open("/proc/sys/vm/drop_caches", "w") as f:
                  f.write("3\n")
          except OSError as e:
              log("DROP_CACHES_FAILED errno=%d" % e.errno)


      def prepare_seed_file():
          tune_zfs_for_fill()
          fill_file(1)
          run(["zfs", "destroy", SNAPSHOT], check=False)
          run(["zfs", "snapshot", SNAPSHOT])


      def reset_seed_file(attempt):
          if attempt > 1:
              run(["zfs", "rollback", "-r", SNAPSHOT])

          try:
              with open("/proc/sys/vm/drop_caches", "w") as f:
                  f.write("3\n")
          except OSError as e:
              log("DROP_CACHES_FAILED errno=%d" % e.errno)


      def puncher():
          fd = os.open(FILE, os.O_RDWR)
          ret = libc.fallocate(
              fd,
              FALLOC_FL_KEEP_SIZE | FALLOC_FL_PUNCH_HOLE,
              0,
              SIZE,
          )
          err = ctypes.get_errno()
          os._exit(0 if ret == 0 else 70)


      def close_fd(fd):
          try:
              os.close(fd)
          except OSError:
              pass


      def detach_stdio():
          fd = os.open("/dev/null", os.O_RDWR)
          try:
              os.dup2(fd, 0)
              os.dup2(fd, 1)
              os.dup2(fd, 2)
          finally:
              close_fd(fd)


      def reader(reader_id, ready_fd, go_fd):
          fd = os.open(FILE, os.O_RDONLY)
          try:
              mm = mmap.mmap(fd, SIZE, access=mmap.ACCESS_READ)
          except BaseException:
              os.close(fd)
              raise

          offsets = []
          total_pages = max(1, SIZE // 4096)
          span_pages = max(1, min(total_pages, READER_SPAN_PAGES))
          start_page = (reader_id * READS_PER_LOOP) % span_pages
          for i in range(READS_PER_LOOP):
              offsets.append(((start_page + i) % span_pages) * 4096)

          os.write(ready_fd, b"1")
          close_fd(ready_fd)
          if os.read(go_fd, 1) != b"1":
              log("READER_ABORTED_%02d=%d" % (reader_id, os.getpid()))
              close_fd(go_fd)
              os._exit(72)
          close_fd(go_fd)

          sink = 0
          while True:
              if hasattr(mm, "madvise") and hasattr(mmap, "MADV_DONTNEED"):
                  try:
                      mm.madvise(mmap.MADV_DONTNEED)
                  except OSError:
                      pass

              for off in offsets:
                  libc.posix_fadvise(fd, off, 4096, POSIX_FADV_DONTNEED)
                  sink ^= mm[off]

              time.sleep(0.001)


      def fork_child(fn, *args):
          pid = os.fork()
          if pid == 0:
              signal.signal(signal.SIGTERM, signal.SIG_DFL)
              detach_stdio()
              try:
                  fn(*args)
                  os._exit(0)
              except BaseException as e:
                  log("CHILD_ERROR pid=%d error=%r" % (os.getpid(), e))
                  os._exit(71)
          return pid


      def fork_reader(reader_id):
          ready_r, ready_w = os.pipe()
          go_r, go_w = os.pipe()
          pid = os.fork()
          if pid == 0:
              close_fd(ready_r)
              close_fd(go_w)
              signal.signal(signal.SIGTERM, signal.SIG_DFL)
              detach_stdio()
              try:
                  reader(reader_id, ready_w, go_r)
                  os._exit(0)
              except BaseException as e:
                  log("CHILD_ERROR pid=%d error=%r" % (os.getpid(), e))
                  os._exit(71)

          close_fd(ready_w)
          close_fd(go_r)
          log("READER_PID_%02d=%d" % (reader_id, pid))
          return {
              "pid": pid,
              "ready_fd": ready_r,
              "go_fd": go_w,
          }


      def wait_for_readers(readers):
          pending = {reader_info["ready_fd"]: reader_info["pid"] for reader_info in readers}
          deadline = time.monotonic() + READER_READY_TIMEOUT

          while pending:
              timeout = deadline - time.monotonic()
              if timeout <= 0:
                  log(
                      "READER_READY_TIMEOUT pending="
                      + ",".join(str(pid) for pid in pending.values())
                  )
                  return False

              readable, _, _ = select.select(list(pending), [], [], timeout)
              for fd in readable:
                  pid = pending.pop(fd)
                  data = os.read(fd, 1)
                  close_fd(fd)
                  if data != b"1":
                      log("READER_READY_FAILED pid=%d" % pid)
                      return False

          log("READERS_READY=%d" % len(readers))
          return True


      def release_readers(readers):
          for reader_info in readers:
              close_fd(reader_info["ready_fd"])
              try:
                  os.write(reader_info["go_fd"], b"1")
              except OSError:
                  pass
              close_fd(reader_info["go_fd"])
          log("READERS_RELEASED=%d" % len(readers))


      def proc_state(pid):
          try:
              stat = open("/proc/%d/stat" % pid).read()
          except OSError:
              return None
          return stat.rsplit(") ", 1)[1].split()[0]


      def proc_stack(pid):
          try:
              return open("/proc/%d/stack" % pid).read()
          except OSError as e:
              return "STACK_UNAVAILABLE pid=%d errno=%d\n" % (pid, e.errno)


      def dump_pid_stack(pid, stack=None):
          state = proc_state(pid)
          if state is None:
              log("PID %d exited" % pid)
              return

          log("PID %d state=%s" % (pid, state))
          sys.stdout.write(stack if stack is not None else proc_stack(pid))
          sys.stdout.flush()


      def dump_lock_inversion(label, punch_pid, punch_stack, reader_matches):
          log("=== %s ===" % label)
          dump_pid_stack(punch_pid, punch_stack)
          for pid, stack in reader_matches:
              dump_pid_stack(pid, stack)


      def dump_attempt_timeout(punch_pid, reader_pids):
          log("=== attempt-timeout-no-lock-inversion ===")
          dump_pid_stack(punch_pid)

          dumped = 0
          for pid in reader_pids:
              state = proc_state(pid)
              if state == "D" or dumped < 4:
                  dump_pid_stack(pid)
                  dumped += 1


      def vulnerable_puncher_stack_matches(stack):
          if "zfs_freesp+0x37f" in stack:
              return True

          if "zfs_freesp" not in stack:
              return False

          lock_needles = [
              "filemap_invalidate_lock",
              "rwsem_down_write_slowpath",
              "down_write",
          ]
          return any(needle in stack for needle in lock_needles)


      def reader_stack_matches(stack):
          return (
              (
                  "zfs_rangelock_enter_impl" in stack
                  or "zfs_rangelock_enter_reader" in stack
                  or "zfs_rangelock_enter" in stack
              )
              and ("zfs_getpage" in stack or "zpl_read_folio" in stack)
          )


      def kill_children(pids):
          for pid in pids:
              try:
                  os.kill(pid, signal.SIGKILL)
              except ProcessLookupError:
                  pass

          remaining = set(pids)
          deadline = time.monotonic() + KILL_WAIT_SECONDS
          while remaining and time.monotonic() < deadline:
              for pid in list(remaining):
                  try:
                      done_pid, _ = os.waitpid(pid, os.WNOHANG)
                  except ChildProcessError:
                      remaining.discard(pid)
                  except OSError:
                      remaining.discard(pid)
                  else:
                      if done_pid == pid:
                          remaining.discard(pid)

              if remaining:
                  time.sleep(0.05)

          for pid in sorted(remaining):
              log("CHILD_UNREAPED_AFTER_SIGKILL pid=%d state=%s" % (pid, proc_state(pid)))
              sys.stdout.write(proc_stack(pid))
              sys.stdout.flush()

          return remaining


      def wait_before_reader_release(punch_pid, release_delay):
          deadline = time.monotonic() + release_delay

          while time.monotonic() < deadline:
              done_pid, status = os.waitpid(punch_pid, os.WNOHANG)
              if done_pid == punch_pid:
                  exit_code = os.waitstatus_to_exitcode(status)
                  log(
                      "PUNCHER_EXITED_BEFORE_READERS status=%d exit_code=%d"
                      % (status, exit_code)
                  )
                  return exit_code

              time.sleep(min(0.005, max(0.0, deadline - time.monotonic())))

          return None


      def puncher_exit_outcome(exit_code, readers_released):
          if exit_code != 0:
              return OUTCOME_PUNCHER_ERROR

          if not readers_released:
              return OUTCOME_EARLY_EXIT

          return OUTCOME_COMPLETED


      def results_exit_status(results, expected_attempts):
          if OUTCOME_REPRODUCED in results:
              return 2

          if len(results) != expected_attempts:
              return 3

          accepted_outcomes = (OUTCOME_COMPLETED, OUTCOME_EARLY_EXIT)
          if (
              OUTCOME_COMPLETED in results
              and all(outcome in accepted_outcomes for outcome in results)
          ):
              return 0

          return 3


      def log_attempt_summary(results):
          log("ATTEMPTS_REQUESTED=%d" % ATTEMPTS)
          log("ATTEMPTS_EXECUTED=%d" % len(results))
          log(
              "ATTEMPTS_COMPLETED=%d"
              % sum(outcome == OUTCOME_COMPLETED for outcome in results)
          )

          for outcome in TERMINAL_OUTCOMES:
              log(
                  "ATTEMPT_OUTCOME_COUNT outcome=%s count=%d"
                  % (outcome, results.count(outcome))
              )


      def self_test_outcomes():
          assert puncher_exit_outcome(0, True) == OUTCOME_COMPLETED
          assert puncher_exit_outcome(0, False) == OUTCOME_EARLY_EXIT
          assert puncher_exit_outcome(70, False) == OUTCOME_PUNCHER_ERROR
          assert puncher_exit_outcome(-signal.SIGKILL, True) == OUTCOME_PUNCHER_ERROR
          assert results_exit_status([OUTCOME_COMPLETED] * 4, 4) == 0
          assert results_exit_status(
              [OUTCOME_COMPLETED, OUTCOME_EARLY_EXIT, OUTCOME_COMPLETED, OUTCOME_EARLY_EXIT],
              4,
          ) == 0
          assert results_exit_status([OUTCOME_EARLY_EXIT] * 4, 4) == 3
          assert results_exit_status([OUTCOME_COMPLETED] * 3, 4) == 3
          assert results_exit_status([OUTCOME_REPRODUCED], 4) == 2

          for outcome in TERMINAL_OUTCOMES:
              if outcome in (OUTCOME_REPRODUCED, OUTCOME_COMPLETED, OUTCOME_EARLY_EXIT):
                  continue

              results = [OUTCOME_COMPLETED, outcome, OUTCOME_COMPLETED, OUTCOME_COMPLETED]
              assert results_exit_status(results, 4) == 3

          log("FALLOCATE_OUTCOME_SELF_TEST=ok")
          return 0


      def attempt_once(attempt):
          release_delay = RELEASE_DELAYS[(attempt - 1) % len(RELEASE_DELAYS)]
          log(
              "ATTEMPT=%d SIZE_MB=%d READERS=%d RELEASE_DELAY_MS=%.3f"
              % (attempt, SIZE_MB, READERS, release_delay * 1000.0)
          )
          tune_zfs_for_fill()
          reset_seed_file(attempt)

          readers = [fork_reader(i) for i in range(READERS)]
          reader_pids = [reader_info["pid"] for reader_info in readers]
          if not wait_for_readers(readers):
              release_readers(readers)
              kill_children(reader_pids)
              return OUTCOME_READER_SETUP_FAILED

          tune_zfs_for_free()
          punch_pid = fork_child(puncher)
          log("PUNCHER_PID=%d" % punch_pid)
          early_exit_code = wait_before_reader_release(punch_pid, release_delay)
          if early_exit_code is not None:
              kill_children(reader_pids)
              return puncher_exit_outcome(early_exit_code, False)

          release_readers(readers)
          pids = [punch_pid] + reader_pids
          stable_since = None
          vulnerable_seen = False
          started = time.monotonic()

          while time.monotonic() - started < ATTEMPT_TIMEOUT:
              done_pid, status = os.waitpid(punch_pid, os.WNOHANG)
              if done_pid == punch_pid:
                  exit_code = os.waitstatus_to_exitcode(status)
                  log("PUNCHER_EXITED status=%d exit_code=%d" % (status, exit_code))
                  kill_children(reader_pids)
                  return puncher_exit_outcome(exit_code, True)

              punch_stack = proc_stack(punch_pid)
              reader_matches = []
              for pid in reader_pids:
                  stack = proc_stack(pid)
                  if reader_stack_matches(stack):
                      reader_matches.append((pid, stack))

              puncher_vulnerable = vulnerable_puncher_stack_matches(punch_stack)
              if puncher_vulnerable and not vulnerable_seen:
                  vulnerable_seen = True
                  log("PUNCHER_VULNERABLE_STACK=1")
                  sys.stdout.write(punch_stack)
                  sys.stdout.flush()

              if puncher_vulnerable and reader_matches:
                  if stable_since is None:
                      stable_since = time.monotonic()
                      log("MATCHING_READER_COUNT=%d" % len(reader_matches))
                      dump_lock_inversion(
                          "candidate-lock-inversion",
                          punch_pid,
                          punch_stack,
                          reader_matches,
                      )
                  elif time.monotonic() - stable_since >= STABLE_SECONDS:
                      dump_lock_inversion(
                          "stable-lock-inversion",
                          punch_pid,
                          punch_stack,
                          reader_matches,
                      )
                      log("REPRODUCED_ZFS_FALLOCATE_DEADLOCK=1")
                      log("PUNCHER_STUCK_PID=%d" % punch_pid)
                      log(
                          "READER_STUCK_PIDS="
                          + ",".join(str(pid) for pid, _ in reader_matches)
                      )
                      return OUTCOME_REPRODUCED
              else:
                  stable_since = None

              elapsed = time.monotonic() - started
              time.sleep(0.05 if elapsed < 10 else 0.5)

          dump_attempt_timeout(punch_pid, reader_pids)
          kill_children(pids)
          return OUTCOME_TIMEOUT


      def main():
          log("UNAME=" + subprocess.check_output(["uname", "-a"], text=True).strip())
          subprocess.run(["zfs", "version"], check=False)
          tune_vm()
          setup_dataset()
          prepare_seed_file()

          results = []
          for attempt in range(1, ATTEMPTS + 1):
              outcome = attempt_once(attempt)
              results.append(outcome)
              log("ATTEMPT_RESULT attempt=%d outcome=%s" % (attempt, outcome))

              if outcome == OUTCOME_REPRODUCED:
                  log_attempt_summary(results)
                  return 2

          run(["zfs", "destroy", "-r", DATASET], check=False)
          log("REPRODUCED_ZFS_FALLOCATE_DEADLOCK=0")
          log_attempt_summary(results)
          return results_exit_status(results, ATTEMPTS)


      if __name__ == "__main__":
          if sys.argv[1:] == ["--self-test-outcomes"]:
              raise SystemExit(self_test_outcomes())

          if len(sys.argv) != 1:
              log("usage: %s [--self-test-outcomes]" % sys.argv[0])
              raise SystemExit(2)

          raise SystemExit(main())
    '';
  in
  {
    name = testName;

    description = ''
      Reproduce the ZFS fallocate/page-fault lock inversion.

      The reproducer creates a 4K-recordsize ZFS file, starts a hole-punching
      fallocate over the whole file, then forces concurrent mmap page faults in
      the same range. On the unfixed lock order, fallocate holds the ZFS range
      writer while mmap faults hold Linux invalidate_lock_shared and wait for a
      ZFS range reader.

      The default regression test runs against fixed ZFS pins and succeeds only
      when every attempt is accounted for, at least one attempt overlaps the
      readers, and no attempt reproduces the lock inversion or reports an error.
      A successful hole punch that finishes before a deliberately delayed reader
      release is benign but does not by itself satisfy the overlap requirement.

      When `expectReproduce` is set, this becomes a manual reproducer for
      vulnerable kernel/ZFS pins. In that mode, matching blocked stacks are
      treated as successful reproduction and the VM is killed afterwards.
    '';

    tags =
      if expectReproduce then
        [
          "manual"
          "regression"
        ]
      else
        [
          "ci"
          "regression"
        ];

    labels = {
      component = "zfs";
      runtime = "long";
      gate = if expectReproduce then "manual" else "ci";
    };

    machine = baseMachine // {
      cores = 4;
      memory = 4096;
      config =
        { ... }:
        {
          imports = baseMachine.config.imports;
          boot.qemu.cpus = 4;
          boot.qemu.cpu.cores = 4;
          boot.qemu.cpu.sockets = 1;
          boot.qemu.memory = 4096;
          environment.systemPackages = [
            pkgs.coreutils
            pkgs.python3
          ];
        };
    };

    testScript = ''
      machine.start
      # Under heavy ZFS/kernel test builds, osctld/pool activation can exceed
      # the default timeout and cause false-negative bootstrap failures.
      machine.wait_for_osctl_pool('tank', timeout: 20 * 60)

      machine.mkdir('/scripts')
      machine.push_file("${reproducer}", "/scripts/reproducer.py")
      _, self_test_output = machine.succeeds('/scripts/reproducer.py --self-test-outcomes')
      expect(self_test_output).to include('FALLOCATE_OUTCOME_SELF_TEST=ok')

      status = nil
      output = ""

      begin
        command = [
          'ZFS_FALLOCATE_DEADLOCK_SIZE_MB=2048',
          'ZFS_FALLOCATE_DEADLOCK_ATTEMPTS=12',
          'ZFS_FALLOCATE_DEADLOCK_READERS=64',
          'ZFS_FALLOCATE_DEADLOCK_RELEASE_DELAYS_MS=0,1,2,5,10,20,50,100,250,500,1000,2000',
          'ZFS_FALLOCATE_DEADLOCK_ATTEMPT_TIMEOUT=75',
          'ZFS_FALLOCATE_DEADLOCK_STABLE_SECONDS=5',
          '/scripts/reproducer.py'
        ].join(' ')

        status, output = machine.execute(command, timeout: 40 * 60)
      ensure
        machine.kill if machine.running?
      end

      if ${expectReproduceRuby}
        fail "reproducer exited with #{status}:\n#{output}" unless status == 2

        expect(output).to include('REPRODUCED_ZFS_FALLOCATE_DEADLOCK=1')
        expect(output).to include('outcome=reproduced')
        expect(output).to include('PUNCHER_VULNERABLE_STACK=1')
        expect(output).to include('zfs_freesp+0x37f')
        expect(output).to include('zfs_rangelock_enter_impl')
        expect(output).to include('zfs_getpage')
        expect(output).to include('zpl_read_folio')
      else
        fail "reproducer unexpectedly exited with #{status}:\n#{output}" unless status == 0

        attempt_results = output.scan(/^ATTEMPT_RESULT attempt=(\d+) outcome=(\S+)$/)
        expect(attempt_results.map(&:first)).to eq((1..12).map(&:to_s))
        outcomes = attempt_results.map(&:last)
        expect(outcomes - ['completed', 'puncher-exited-before-reader-release']).to be_empty
        expect(outcomes.count('completed')).to be > 0
        expect(output).to include('ATTEMPTS_REQUESTED=12')
        expect(output).to include('ATTEMPTS_EXECUTED=12')
        expect(output).to include("ATTEMPTS_COMPLETED=#{outcomes.count('completed')}")
        [
          'reader-setup-failed',
          'puncher-error',
          'attempt-timeout',
        ].each do |outcome|
          expect(output).to include("ATTEMPT_OUTCOME_COUNT outcome=#{outcome} count=0")
        end
        expect(output).to include('REPRODUCED_ZFS_FALLOCATE_DEADLOCK=0')
        expect(output).not_to include('REPRODUCED_ZFS_FALLOCATE_DEADLOCK=1')
        expect(output).not_to include('stable-lock-inversion')
      end
    '';
  }
)

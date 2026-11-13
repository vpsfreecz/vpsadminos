{ pkgs }:

let
  workload = pkgs.writeTextFile {
    name = "livepatch-generic-workload";
    destination = "/bin/livepatch-generic-workload";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3

      import hashlib
      import json
      import os
      import shutil
      import signal
      import socket
      import subprocess
      import sys
      import time
      import uuid
      from pathlib import Path

      STATE = Path("/run/livepatch-generic-workload")
      TREE = Path("/var/tmp/livepatch-generic-workload")
      CGROUP = Path("/sys/fs/cgroup/livepatch-generic-workload")
      TRUE = "${pkgs.coreutils}/bin/true"
      DIMENSIONS = (
          "cpu",
          "scheduler",
          "forkExec",
          "cgroupMigration",
          "loopbackNetwork",
          "filesystemIntegrity",
      )


      def fail(message):
          raise RuntimeError(message)


      def atomic_write(path, value):
          temporary = path.with_name(f".{path.name}.{os.getpid()}")
          with open(temporary, "w", encoding="utf-8") as handle:
              handle.write(value)
              handle.flush()
              os.fsync(handle.fileno())
          os.replace(temporary, path)


      def process_start_time(pid):
          fields = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").split()
          return int(fields[21])


      def process_state(dimension, entry):
          pid = entry["pid"]
          proc = Path(f"/proc/{pid}")
          if not proc.exists():
              return "gone"
          try:
              command = (proc / "cmdline").read_bytes().split(b"\0")
              start_time = process_start_time(pid)
              pgid = os.getpgid(pid)
          except (FileNotFoundError, ProcessLookupError):
              return "gone"
          expected = [b"worker", dimension.encode("ascii")]
          if (
              start_time != entry["startTime"]
              or pgid != entry["pgid"]
              or entry["pid"] != entry["pgid"]
              or not all(token in command for token in expected)
          ):
              return "foreign"
          return "owned"


      def require_owner():
          owner = STATE / "owner.json"
          if owner.is_symlink() or not owner.is_file():
              fail("owner record is missing")
          value = json.loads(owner.read_text(encoding="utf-8"))
          if sorted(value) != ["schemaVersion", "token"] or value["schemaVersion"] != 1:
              fail("owner record is malformed")
          if not isinstance(value["token"], str) or not value["token"]:
              fail("owner token is malformed")
          return value


      def load_pids():
          path = STATE / "pids.json"
          if path.is_symlink() or not path.is_file():
              fail("worker identity record is missing")
          value = json.loads(path.read_text(encoding="utf-8"))
          if sorted(value) != sorted(DIMENSIONS):
              fail("worker identity set is incomplete")
          for dimension, entry in value.items():
              if sorted(entry) != ["pgid", "pid", "startTime"]:
                  fail(f"worker identity is malformed: {dimension}")
              if not all(isinstance(entry[key], int) and entry[key] > 0 for key in entry):
                  fail(f"worker identity is invalid: {dimension}")
          return value


      def counter_path(dimension):
          return STATE / "counters" / dimension


      def publish_counter(dimension, value):
          atomic_write(counter_path(dimension), f"{value}\n")


      def stopped():
          return (STATE / "stop").exists()


      def run_cpu(count):
          value = b"vpsAdminOS livepatch generic CPU workload"
          for _ in range(1024):
              value = hashlib.sha256(value).digest()
          return count + 1


      def run_scheduler(count):
          for _ in range(4096):
              os.sched_yield()
          return count + 1


      def run_fork_exec(count):
          subprocess.run(
              [TRUE],
              check=True,
              stdin=subprocess.DEVNULL,
              stdout=subprocess.DEVNULL,
              stderr=subprocess.DEVNULL,
          )
          return count + 1


      def run_cgroup_migration(count):
          target = CGROUP / ("a" if count % 2 == 0 else "b") / "cgroup.procs"
          target.write_text(f"{os.getpid()}\n", encoding="ascii")
          return count + 1


      def run_loopback_network(count):
          payload = f"livepatch-loopback-{count}".encode("ascii")
          with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
              listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
              listener.bind(("127.0.0.1", 0))
              listener.listen(1)
              with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
                  client.settimeout(2)
                  client.connect(listener.getsockname())
                  server, _ = listener.accept()
                  with server:
                      server.settimeout(2)
                      client.sendall(payload)
                      received = server.recv(len(payload))
                      if received != payload:
                          fail("loopback request payload mismatch")
                      server.sendall(received)
                      if client.recv(len(payload)) != payload:
                          fail("loopback response payload mismatch")
          return count + 1


      def run_filesystem_integrity(count):
          directory = TREE / "filesystem"
          payload = f"livepatch-filesystem-{count}\n".encode("ascii")
          expected = hashlib.sha256(payload).hexdigest()
          temporary = directory / "pending"
          current = directory / "current"
          descriptor = os.open(temporary, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
          try:
              os.write(descriptor, payload)
              os.fsync(descriptor)
          finally:
              os.close(descriptor)
          os.replace(temporary, current)
          directory_descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
          try:
              os.fsync(directory_descriptor)
          finally:
              os.close(directory_descriptor)
          if hashlib.sha256(current.read_bytes()).hexdigest() != expected:
              fail("filesystem checksum mismatch")
          return count + 1


      WORKERS = {
          "cpu": run_cpu,
          "scheduler": run_scheduler,
          "forkExec": run_fork_exec,
          "cgroupMigration": run_cgroup_migration,
          "loopbackNetwork": run_loopback_network,
          "filesystemIntegrity": run_filesystem_integrity,
      }


      def worker(dimension):
          if dimension not in WORKERS:
              fail("unknown worker dimension")
          count = 0
          try:
              while not stopped():
                  count = WORKERS[dimension](count)
                  publish_counter(dimension, count)
          except BaseException as error:
              atomic_write(STATE / f"error.{dimension}", f"{type(error).__name__}: {error}\n")
              return 1
          return 0


      def start():
          for path in (STATE, TREE, CGROUP):
              if path.exists() or path.is_symlink():
                  fail(f"refusing pre-existing workload path: {path}")
          if not Path("/sys/fs/cgroup/cgroup.controllers").is_file():
              fail("cgroup v2 is unavailable")

          STATE.mkdir(mode=0o700)
          (STATE / "counters").mkdir(mode=0o700)
          TREE.mkdir(mode=0o700)
          (TREE / "filesystem").mkdir(mode=0o700)
          CGROUP.mkdir(mode=0o755)
          (CGROUP / "a").mkdir(mode=0o755)
          (CGROUP / "b").mkdir(mode=0o755)
          atomic_write(
              STATE / "owner.json",
              json.dumps({"schemaVersion": 1, "token": uuid.uuid4().hex}, sort_keys=True) + "\n",
          )

          records = {}
          try:
              for dimension in DIMENSIONS:
                  log = open(STATE / f"{dimension}.log", "ab", buffering=0)
                  try:
                      child = subprocess.Popen(
                          [sys.argv[0], "worker", dimension],
                          stdin=subprocess.DEVNULL,
                          stdout=log,
                          stderr=log,
                          start_new_session=True,
                      )
                  finally:
                      log.close()
                  records[dimension] = {
                      "pid": child.pid,
                      "pgid": os.getpgid(child.pid),
                      "startTime": process_start_time(child.pid),
                  }
                  atomic_write(STATE / "pids.json", json.dumps(records, sort_keys=True) + "\n")

              deadline = time.monotonic() + 15
              while time.monotonic() < deadline:
                  if all(counter_path(dimension).is_file() for dimension in DIMENSIONS):
                      break
                  for dimension, entry in records.items():
                      if process_state(dimension, entry) != "owned":
                          fail(f"worker exited before readiness: {dimension}")
                  time.sleep(0.02)
              else:
                  fail("workers did not become ready")
              snapshot()
          except BaseException:
              cleanup(allow_partial=True)
              raise


      def snapshot_values():
          require_owner()
          records = load_pids()
          errors = sorted(STATE.glob("error.*"))
          if errors:
              fail(errors[0].read_text(encoding="utf-8").strip())
          values = {}
          for dimension in DIMENSIONS:
              if process_state(dimension, records[dimension]) != "owned":
                  fail(f"worker is not alive and owned: {dimension}")
              path = counter_path(dimension)
              if path.is_symlink() or not path.is_file():
                  fail(f"counter is missing: {dimension}")
              raw = path.read_text(encoding="ascii").strip()
              if not raw.isdigit() or int(raw) <= 0:
                  fail(f"counter is invalid: {dimension}")
              values[dimension] = int(raw)
          return values


      def snapshot():
          print(json.dumps(snapshot_values(), sort_keys=True, separators=(",", ":")))


      def progress(baseline):
          expected = json.loads(baseline)
          if sorted(expected) != sorted(DIMENSIONS):
              fail("progress baseline dimensions are invalid")
          values = snapshot_values()
          for dimension in DIMENSIONS:
              if not isinstance(expected[dimension], int) or expected[dimension] <= 0:
                  fail(f"progress baseline is invalid: {dimension}")
              if values[dimension] <= expected[dimension]:
                  fail(f"workload did not progress: {dimension}")
          print(json.dumps(values, sort_keys=True, separators=(",", ":")))


      def cleanup(allow_partial=False):
          if not STATE.exists() and allow_partial:
              return
          require_owner()
          records_path = STATE / "pids.json"
          records = json.loads(records_path.read_text(encoding="utf-8")) if records_path.is_file() else {}
          if not allow_partial and sorted(records) != sorted(DIMENSIONS):
              fail("worker identity set is incomplete")

          (STATE / "stop").touch(mode=0o600, exist_ok=True)
          deadline = time.monotonic() + 20
          while time.monotonic() < deadline:
              states = {
                  dimension: process_state(dimension, entry)
                  for dimension, entry in records.items()
              }
              if any(value == "foreign" for value in states.values()):
                  fail("worker identity changed during cleanup")
              if all(value == "gone" for value in states.values()):
                  break
              time.sleep(0.05)
          else:
              for dimension, entry in records.items():
                  state = process_state(dimension, entry)
                  if state == "foreign":
                      fail(f"refusing foreign process during cleanup: {dimension}")
                  if state == "owned":
                      os.killpg(entry["pgid"], signal.SIGTERM)
              deadline = time.monotonic() + 5
              while time.monotonic() < deadline:
                  states = {
                      dimension: process_state(dimension, entry)
                      for dimension, entry in records.items()
                  }
                  if any(value == "foreign" for value in states.values()):
                      fail("worker identity changed after termination")
                  if all(value == "gone" for value in states.values()):
                      break
                  time.sleep(0.05)
              else:
                  fail("owned workers did not terminate")

          for child in (CGROUP / "a", CGROUP / "b"):
              if child.exists():
                  child.rmdir()
          if CGROUP.exists():
              CGROUP.rmdir()
          if TREE.exists():
              shutil.rmtree(TREE)
          shutil.rmtree(STATE)
          if any(path.exists() or path.is_symlink() for path in (STATE, TREE, CGROUP)):
              fail("owned workload paths remain after cleanup")
          print('{"cleanupComplete":true}')


      def main():
          if len(sys.argv) < 2:
              fail("command is required")
          command = sys.argv[1]
          if command == "worker" and len(sys.argv) == 3:
              return worker(sys.argv[2])
          if command == "start" and len(sys.argv) == 2:
              start()
              return 0
          if command == "snapshot" and len(sys.argv) == 2:
              snapshot()
              return 0
          if command == "progress" and len(sys.argv) == 3:
              progress(sys.argv[2])
              return 0
          if command == "cleanup" and len(sys.argv) == 2:
              cleanup()
              return 0
          fail("unsupported command")


      if __name__ == "__main__":
          try:
              sys.exit(main())
          except BaseException as error:
              print(f"livepatch-generic-workload: {error}", file=sys.stderr)
              sys.exit(1)
    '';
  };
in
{
  modules = [
    {
      environment.systemPackages = [
        workload
        pkgs.util-linux
      ];
    }
  ];
}

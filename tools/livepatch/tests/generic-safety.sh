#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
validator=${1:-$repository_root/tools/livepatch/validate-generic-result.sh}
verifier=${2:-$repository_root/tools/livepatch/verify.sh}
ruby=${3:-ruby}
generic_template=${4:-$repository_root/tests/suite/kernel/livepatch-set.nix}
nfs_validator=${5-}
nfs_oracle_script=${6-}
nfs_plan=${7-}
nfs_capture=${8-}
python=${9:-python3}
workload_source=${10:-$repository_root/tests/suite/kernel/livepatch-set/workload.nix}
workload_executable=${11-}
profile_runner=${12-}
profile_store_config=${13-}
if [[ -z "$workload_executable" || ! -f "$workload_executable" || -L "$workload_executable" || ! -x "$workload_executable" ]]; then
  echo 'generated livepatch workload executable is required' >&2
  exit 1
fi
if [[ -z "$profile_runner" || ! -f "$profile_runner" || -L "$profile_runner" || ! -x "$profile_runner" ]]; then
  echo 'livepatch profile runner is required' >&2
  exit 1
fi
if [[ "$profile_store_config" != /nix/store/* || ! -f "$profile_store_config" || -L "$profile_store_config" ]]; then
  echo 'Nix-supplied livepatch profile config is required' >&2
  exit 1
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

dimensions='["cpu","scheduler","forkExec","cgroupMigration","loopbackNetwork","filesystemIntegrity"]'
counters_one='{"cpu":1,"scheduler":1,"forkExec":1,"cgroupMigration":1,"loopbackNetwork":1,"filesystemIntegrity":1}'
counters_two='{"cpu":2,"scheduler":2,"forkExec":2,"cgroupMigration":2,"loopbackNetwork":2,"filesystemIntegrity":2}'
counters_three='{"cpu":3,"scheduler":3,"forkExec":3,"cgroupMigration":3,"loopbackNetwork":3,"filesystemIntegrity":3}'

jq -n \
  --argjson dimensions "$dimensions" \
  --argjson one "$counters_one" \
  --argjson two "$counters_two" \
  --argjson three "$counters_three" '
  def row($id; $profile; $role): {
    rowId: $id,
    setId: "6.12.113.1",
    profileId: $profile,
    role: $role,
    scope: "set",
    testAdapter: "kernel/livepatch-set",
    template: "kernel/livepatch-set",
    timeoutClass: "synthetic",
    expectedOutcome: "success",
    validator: "builtin/generic-livepatch-safety-v1",
    oracleIds: [],
    oracleShard: "none",
    runnerClass: "amd-livepatch",
    supported: true,
    platform: {id: "amd", runnerClass: "amd-livepatch", supported: true},
    aging: (
      if $role == "aged-transition" then {
        evidenceClass: "development-short",
        dwellSeconds: 300,
        developmentDwellSeconds: 300,
        releaseDwellSeconds: 1800,
        checkpointSeconds: 60
      } else null end
    )
  };
  [
    row("generic-aged-amd"; "set/vendor-aged-transition"; "aged-transition"),
    row("generic-lifecycle-amd"; "set/vendor-lifecycle"; "lifecycle"),
    row("generic-busy-amd"; "set/vendor-busy-transition"; "busy-transition"),
    row("generic-failure-amd"; "set/vendor-failure-recovery"; "failure-recovery")
  ] as $rows
  | {
      schemaVersion: 1,
      dormant: false,
      selectedSets: 1,
      sourceRevision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      system: "x86_64-linux",
      releases: [{release: "6.12.113.1", kernelVersion: "6.12.113", payloadRevision: 1, releaseOrdinal: 1}],
      sets: [{
        id: "6.12.113.1",
        kernelVersion: "6.12.113",
        tipRelease: "6.12.113.1",
        oracleIds: [],
        oracles: [],
        members: [{
          release: "6.12.113.1",
          kernelVersion: "6.12.113",
          payloadRevision: 1,
          releaseOrdinal: 1,
          predecessorRelease: null,
          producerAttr: "synthetic",
          fixIds: ["synthetic"],
          oracleIds: []
        }]
      }],
      rows: $rows,
      coverage: [],
      matrix: {include: ($rows | map({rowId, setId, profileId, runnerClass, timeoutClass, expectedOutcome}))},
      counts: {
        catalogReleases: 1,
        normalizedReleases: 1,
        plannedMembers: 1,
        requiredProfilePlatformTuples: 4,
        activeOracles: 0,
        coverageTuples: 0,
        plannedRows: 4,
        matrixRows: 4
      }
    }
' >"$work/plan.json"

jq -c '
  (.rows[] | select(.role == "aged-transition") | .aging.evidenceClass) = "release"
  | (.rows[] | select(.role == "aged-transition") | .aging.dwellSeconds) = 1800
' "$work/plan.json" >"$work/plan-release.json"

jq -n '{
  schemaVersion: 1,
  sourceRevision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  flakeLockSha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  rawBuildLogIdentity: "per-realization-only",
  selectedSets: 1,
  counts: {plannedMembers: 1, capturedMembers: 1},
  sets: [{
    id: "6.12.113.1",
    members: [{
      release: "6.12.113.1",
      identity: {
        producer: "/nix/store/00000000000000000000000000000000-synthetic-producer",
        module: "/nix/store/00000000000000000000000000000000-synthetic-producer/synthetic.ko",
        moduleName: "synthetic_livepatch",
        moduleSha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        targetId: "synthetic-target",
        inputDigest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        manifestSha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        inspectionSha256: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        closureSha256: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        vermagic: "6.12.113 synthetic",
        sourceRevision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        flakeLockSha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      audit: {
        deriver: "/nix/store/00000000000000000000000000000000-synthetic-producer.drv",
        requisites: ["/nix/store/00000000000000000000000000000000-synthetic-producer"],
        expectedInspectionSha256: "1111111111111111111111111111111111111111111111111111111111111111",
        frameworkSha256: "2222222222222222222222222222222222222222222222222222222222222222",
        generatedHeaderSha256: "3333333333333333333333333333333333333333333333333333333333333333",
        changedObjectsSha256: "4444444444444444444444444444444444444444444444444444444444444444",
        buildLogSha256: "5555555555555555555555555555555555555555555555555555555555555555",
        buildLogIdentity: "per-realization-only"
      }
    }]
  }]
}' >"$work/capture.json"

jq -e '
  (.sets[0].members[0] | keys | sort) == ["audit", "identity", "release"]
  and (.sets[0].members[0] | has("kernelVersion") | not)
  and (.sets[0].members[0].identity | keys | sort) == [
    "closureSha256", "flakeLockSha256", "inputDigest", "inspectionSha256",
    "manifestSha256", "module", "moduleName", "moduleSha256", "producer",
    "sourceRevision", "targetId", "vermagic"
  ]
  and (.sets[0].members[0].audit | keys | sort) == [
    "buildLogIdentity", "buildLogSha256", "changedObjectsSha256", "deriver",
    "expectedInspectionSha256", "frameworkSha256", "generatedHeaderSha256",
    "requisites"
  ]
' "$work/capture.json" >/dev/null

awk '
  /F6_GENERIC_CAPTURE_RELATION_BEGIN/ { capture = 1; next }
  /F6_GENERIC_CAPTURE_RELATION_END/ { capture = 0 }
  capture { print }
' "$generic_template" >"$work/generic-capture-relation-method.rb"
[[ -s "$work/generic-capture-relation-method.rb" ]]

{
  printf 'require "json"\n\nclass GenericCaptureRelation\n'
  cat "$work/generic-capture-relation-method.rb"
  cat <<'RUBY'
  def initialize(planned_set, captured_set)
    @set = planned_set
    @captured_set = captured_set
  end
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def refuse(label)
  yield
rescue KeyError, RuntimeError
  return
else
  raise "generic capture relation unexpectedly accepted #{label}"
end

planned_set = {
  'kernelVersion' => '6.12.113',
  'members' => [{'release' => '6.12.113.1', 'kernelVersion' => '6.12.113'}],
}
captured_set = {'members' => [{'release' => '6.12.113.1'}]}
GenericCaptureRelation.new(planned_set, captured_set).validate_capture_relation

missing_target = deep_copy(planned_set)
missing_target.fetch('members').fetch(0).delete('kernelVersion')
refuse('missing planned member target') do
  GenericCaptureRelation.new(missing_target, captured_set).validate_capture_relation
end

mismatched_target = deep_copy(planned_set)
mismatched_target.fetch('members').fetch(0)['kernelVersion'] = '6.12.114'
refuse('mismatched planned member target') do
  GenericCaptureRelation.new(mismatched_target, captured_set).validate_capture_relation
end

mismatched_release = deep_copy(captured_set)
mismatched_release.fetch('members').fetch(0)['release'] = '6.12.113.2'
refuse('capture/plan release mismatch') do
  GenericCaptureRelation.new(planned_set, mismatched_release).validate_capture_relation
end

two_member_plan = deep_copy(planned_set)
two_member_plan.fetch('members') << {
  'release' => '6.12.113.2',
  'kernelVersion' => '6.12.113',
}
reordered_capture = {
  'members' => [
    {'release' => '6.12.113.2'},
    {'release' => '6.12.113.1'},
  ],
}
refuse('reordered members') do
  GenericCaptureRelation.new(two_member_plan, reordered_capture).validate_capture_relation
end

extra_capture = deep_copy(captured_set)
extra_capture.fetch('members') << {'release' => '6.12.113.2'}
refuse('extra captured member') do
  GenericCaptureRelation.new(planned_set, extra_capture).validate_capture_relation
end

puts 'generic livepatch capture relation passed'
RUBY
} >"$work/generic-capture-relation.rb"

"$ruby" "$work/generic-capture-relation.rb"

grep -F 'TREE = Path("/tmp/livepatch-generic-workload")' "$workload_source" >/dev/null
if grep -F '/var/tmp/livepatch-generic-workload' "$workload_source" >/dev/null; then
  echo 'generic workload still uses the absent /var/tmp parent' >&2
  exit 1
fi

{
  awk '
    /F7_WORKLOAD_ADMISSION_BEGIN/ { capture = 1; next }
    /F7_WORKLOAD_ADMISSION_END/ { capture = 0 }
    capture { print }
  ' "$workload_source"
  awk '
    /F7_WORKLOAD_CREATION_BEGIN/ { capture = 1; next }
    /F7_WORKLOAD_CREATION_END/ { capture = 0 }
    capture { print }
  ' "$workload_source"
} | sed 's/^      //' >"$work/workload-init-helpers.py"
[[ -s "$work/workload-init-helpers.py" ]]

{
  cat <<'PYTHON'
import os
import shutil
import stat
import tempfile
from pathlib import Path


def fail(message):
    raise RuntimeError(message)


PYTHON
  cat "$work/workload-init-helpers.py"
  cat <<'PYTHON'


def configure(state, tree, cgroup):
    global STATE, TREE, CGROUP
    STATE = state
    TREE = tree
    CGROUP = cgroup


def fixture(label):
    root = Path(tempfile.mkdtemp(prefix=f"livepatch-workload-{label}-"))
    state_parent = root / "run"
    tree_parent = root / "tmp"
    cgroup_parent = root / "cgroup"
    for parent in (state_parent, tree_parent, cgroup_parent):
        parent.mkdir(mode=0o700)
    (cgroup_parent / "cgroup.controllers").write_text("cpu\n", encoding="ascii")
    return root, state_parent, tree_parent, cgroup_parent


def configure_roots(state_parent, tree_parent, cgroup_parent):
    configure(
        state_parent / "livepatch-generic-workload",
        tree_parent / "livepatch-generic-workload",
        cgroup_parent / "livepatch-generic-workload",
    )


def inventory(root):
    entries = []
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        directory_path = Path(directory)
        names.sort()
        files.sort()
        for name in names + files:
            path = directory_path / name
            relative = str(path.relative_to(root))
            metadata = path.lstat()
            mode = stat.S_IMODE(metadata.st_mode)
            if path.is_symlink():
                value = ("symlink", os.readlink(path))
            elif path.is_dir():
                value = ("directory", mode)
            elif path.is_file():
                value = ("file", mode, path.read_bytes())
            else:
                value = ("other", mode)
            entries.append((relative, value))
    return entries


def attempt_start_paths():
    admit_start_paths()
    create_start_paths()


def require_refusal(label, setup):
    root, state_parent, tree_parent, cgroup_parent = fixture(label)
    try:
        configure_roots(state_parent, tree_parent, cgroup_parent)
        setup(root, state_parent, tree_parent, cgroup_parent)
        before = inventory(root)
        try:
            attempt_start_paths()
        except RuntimeError:
            pass
        else:
            raise AssertionError(f"workload initialization unexpectedly accepted {label}")
        after = inventory(root)
        if after != before:
            raise AssertionError(f"workload refusal changed fixture state: {label}")
    finally:
        shutil.rmtree(root)


success_root, state_parent, tree_parent, cgroup_parent = fixture("success")
try:
    configure_roots(state_parent, tree_parent, cgroup_parent)
    previous_umask = os.umask(0)
    try:
        attempt_start_paths()
    finally:
        os.umask(previous_umask)
    expected = {
        STATE: 0o700,
        STATE / "counters": 0o700,
        TREE: 0o700,
        TREE / "filesystem": 0o700,
        CGROUP: 0o755,
        CGROUP / "a": 0o755,
        CGROUP / "b": 0o755,
    }
    for path, expected_mode in expected.items():
        if path.is_symlink() or not path.is_dir():
            raise AssertionError(f"workload path was not created as a directory: {path}")
        actual_mode = stat.S_IMODE(path.stat().st_mode)
        if actual_mode != expected_mode:
            raise AssertionError(
                f"workload path mode mismatch for {path}: {actual_mode:o} != {expected_mode:o}",
            )
    actual_children = {
        path
        for root in (STATE, TREE, CGROUP)
        for path in root.rglob("*")
    }
    if actual_children != set(expected) - {STATE, TREE, CGROUP}:
        raise AssertionError("workload initialization created an unexpected child")
finally:
    shutil.rmtree(success_root)


def existing_root(which):
    def setup(_root, _state_parent, _tree_parent, _cgroup_parent):
        path = {"state": STATE, "tree": TREE, "cgroup": CGROUP}[which]
        path.mkdir(mode=0o711)
        (path / "sentinel").write_text(f"{which}-sentinel\n", encoding="ascii")

    return setup


def symlink_root(which):
    def setup(root, _state_parent, _tree_parent, _cgroup_parent):
        path = {"state": STATE, "tree": TREE, "cgroup": CGROUP}[which]
        target = root / f"{which}-root-target"
        target.mkdir(mode=0o711)
        (target / "sentinel").write_text(f"{which}-symlink-sentinel\n", encoding="ascii")
        path.symlink_to(target, target_is_directory=True)

    return setup


def missing_parent(which):
    def setup(_root, state_parent, tree_parent, cgroup_parent):
        parent = {"state": state_parent, "tree": tree_parent, "cgroup": cgroup_parent}[which]
        shutil.rmtree(parent)

    return setup


def symlink_parent(which):
    def setup(root, state_parent, tree_parent, cgroup_parent):
        parent = {"state": state_parent, "tree": tree_parent, "cgroup": cgroup_parent}[which]
        shutil.rmtree(parent)
        target = root / f"{which}-parent-target"
        target.mkdir(mode=0o700)
        if which == "cgroup":
            (target / "cgroup.controllers").write_text("cpu\n", encoding="ascii")
        parent.symlink_to(target, target_is_directory=True)

    return setup


def nondirectory_parent(which):
    def setup(_root, state_parent, tree_parent, cgroup_parent):
        parent = {"state": state_parent, "tree": tree_parent, "cgroup": cgroup_parent}[which]
        shutil.rmtree(parent)
        parent.write_text(f"{which}-parent-file\n", encoding="ascii")

    return setup


def missing_controllers(_root, _state_parent, _tree_parent, cgroup_parent):
    (cgroup_parent / "cgroup.controllers").unlink()


def symlink_controllers(root, _state_parent, _tree_parent, cgroup_parent):
    controllers = cgroup_parent / "cgroup.controllers"
    controllers.unlink()
    target = root / "controllers-target"
    target.write_text("cpu\n", encoding="ascii")
    controllers.symlink_to(target)


def nonregular_controllers(_root, _state_parent, _tree_parent, cgroup_parent):
    controllers = cgroup_parent / "cgroup.controllers"
    controllers.unlink()
    controllers.mkdir(mode=0o700)


for root_name in ("state", "tree", "cgroup"):
    require_refusal(f"pre-existing-{root_name}", existing_root(root_name))
    require_refusal(f"symlink-{root_name}", symlink_root(root_name))
    require_refusal(f"missing-{root_name}-parent", missing_parent(root_name))
    require_refusal(f"symlink-{root_name}-parent", symlink_parent(root_name))
    require_refusal(f"non-directory-{root_name}-parent", nondirectory_parent(root_name))

require_refusal("missing-cgroup-controllers", missing_controllers)
require_refusal("symlink-cgroup-controllers", symlink_controllers)
require_refusal("non-regular-cgroup-controllers", nonregular_controllers)

print("generic workload initialization matrix passed")
PYTHON
} >"$work/workload-init-matrix.py"

"$python" -m py_compile "$work/workload-init-matrix.py"
"$python" "$work/workload-init-matrix.py"

cat <<'PYTHON' >"$work/workload-cli-matrix.py"
import ast
import contextlib
import io
import runpy
import sys
from pathlib import Path


workload = Path(sys.argv[1])
source = workload.read_text(encoding="utf-8")
syntax = ast.parse(source, filename=str(workload))


def is_main_guard(node):
    return (
        isinstance(node, ast.If)
        and isinstance(node.test, ast.Compare)
        and isinstance(node.test.left, ast.Name)
        and node.test.left.id == "__name__"
        and len(node.test.ops) == 1
        and isinstance(node.test.ops[0], ast.Eq)
        and len(node.test.comparators) == 1
        and isinstance(node.test.comparators[0], ast.Constant)
        and node.test.comparators[0].value == "__main__"
    )


guards = [node for node in syntax.body if is_main_guard(node)]
if len(guards) != 1:
    raise AssertionError("generated workload must have one module-level main guard")
guard = guards[0]
if len(guard.body) != 1 or not isinstance(guard.body[0], ast.Expr):
    raise AssertionError("generated workload main guard has an unexpected body")
exit_call = guard.body[0].value
if not (
    isinstance(exit_call, ast.Call)
    and isinstance(exit_call.func, ast.Attribute)
    and isinstance(exit_call.func.value, ast.Name)
    and exit_call.func.value.id == "sys"
    and exit_call.func.attr == "exit"
    and len(exit_call.args) == 1
    and not exit_call.keywords
    and isinstance(exit_call.args[0], ast.Call)
    and isinstance(exit_call.args[0].func, ast.Name)
    and exit_call.args[0].func.id == "entrypoint"
    and not exit_call.args[0].args
    and not exit_call.args[0].keywords
):
    raise AssertionError("generated workload main guard must call sys.exit(entrypoint())")
if any(isinstance(node, ast.Try) for node in ast.walk(guard)):
    raise AssertionError("generated workload module exit must remain outside the handler")

loaded = runpy.run_path(str(workload), run_name="livepatch_workload_f8")
main = loaded["main"]
entrypoint = loaded["entrypoint"]
namespace = main.__globals__
if entrypoint.__globals__ is not namespace:
    raise AssertionError("generated workload functions do not share one namespace")


class CommandCall:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.calls = []

    def __call__(self, *args):
        self.calls.append(args)
        if self.error is not None:
            raise self.error
        return self.result


def invoke(arguments, command_name, command):
    previous_argv = sys.argv
    previous_command = namespace[command_name]
    stdout = io.StringIO()
    stderr = io.StringIO()
    sys.argv = [str(workload), *arguments]
    namespace[command_name] = command
    try:
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                status = entrypoint()
            except BaseException as error:
                return ("raised", error, stdout.getvalue(), stderr.getvalue())
            return ("returned", status, stdout.getvalue(), stderr.getvalue())
    finally:
        namespace[command_name] = previous_command
        sys.argv = previous_argv


def require_return(label, arguments, command_name, command, expected_status, expected_calls):
    outcome = invoke(arguments, command_name, command)
    expected = ("returned", expected_status, "", "")
    if outcome != expected:
        raise AssertionError(f"{label} outcome mismatch: {outcome!r} != {expected!r}")
    if command.calls != expected_calls:
        raise AssertionError(f"{label} calls mismatch: {command.calls!r} != {expected_calls!r}")


start_success = CommandCall()
require_return("start success", ["start"], "start", start_success, 0, [()])

start_failure = CommandCall(error=RuntimeError("start failed"))
outcome = invoke(["start"], "start", start_failure)
expected = ("returned", 1, "", "livepatch-generic-workload: start failed\n")
if outcome != expected:
    raise AssertionError(f"start failure outcome mismatch: {outcome!r} != {expected!r}")
if start_failure.calls != [()]:
    raise AssertionError(f"start failure call mismatch: {start_failure.calls!r}")

snapshot_success = CommandCall()
require_return("snapshot success", ["snapshot"], "snapshot", snapshot_success, 0, [()])

baseline = '{"cpu":1}'
progress_success = CommandCall()
require_return(
    "progress success",
    ["progress", baseline],
    "progress",
    progress_success,
    0,
    [(baseline,)],
)

cleanup_success = CommandCall()
require_return("cleanup success", ["cleanup"], "cleanup", cleanup_success, 0, [()])

worker_success = CommandCall(result=0)
require_return("worker success", ["worker", "cpu"], "worker", worker_success, 0, [("cpu",)])

worker_failure = CommandCall(result=1)
require_return("worker failure", ["worker", "cpu"], "worker", worker_failure, 1, [("cpu",)])

system_exit = SystemExit(7)
system_exit_call = CommandCall(error=system_exit)
outcome = invoke(["start"], "start", system_exit_call)
if outcome != ("raised", system_exit, "", "") or system_exit_call.calls != [()]:
    raise AssertionError(f"SystemExit propagation mismatch: {outcome!r}")


class ControlFlow(BaseException):
    pass


control_flow = ControlFlow("sentinel")
control_flow_call = CommandCall(error=control_flow)
outcome = invoke(["start"], "start", control_flow_call)
if outcome != ("raised", control_flow, "", "") or control_flow_call.calls != [()]:
    raise AssertionError(f"BaseException propagation mismatch: {outcome!r}")

print("generic workload CLI exit matrix passed")
PYTHON

"$python" -m py_compile "$work/workload-cli-matrix.py"
"$python" "$work/workload-cli-matrix.py" "$workload_executable"

extract_marked_body() {
  local begin=$1
  local end=$2
  local source=$3
  local output=$4

  [[ $(grep -F -c -- "$begin" "$source") -eq 1 ]]
  [[ $(grep -F -c -- "$end" "$source") -eq 1 ]]
  awk -v begin="$begin" -v end="$end" '
    index($0, begin) { capture = 1; next }
    index($0, end) { capture = 0 }
    capture { print }
  ' "$source" >"$output"
  [[ -s "$output" ]]
}

extract_marked_body AGE1_GENERIC_AGING_BEGIN AGE1_GENERIC_AGING_END \
  "$generic_template" "$work/aging-methods.rb"
{
  cat <<'RUBY'
require 'json'

WORKLOAD_DIMENSIONS = %w[
  cpu scheduler forkExec cgroupMigration loopbackNetwork filesystemIntegrity
].freeze

class SyntheticProgressFailure < StandardError
end

class AgedConsumer
RUBY
  cat "$work/aging-methods.rb"
  cat <<'RUBY'
  attr_reader :events

  def initialize(fail_progress_at: nil)
    @events = []
    @now = 0.0
    @progress_calls = 0
    @fail_progress_at = fail_progress_at
    @counters = WORKLOAD_DIMENSIONS.to_h { |dimension| [dimension, 1] }
    @machine = FakeMachine.new(@events)
  end

  def machine
    @machine
  end

  def monotonic_seconds
    @now
  end

  def aging_sleep(seconds)
    raise "unexpected sleep duration #{seconds}" unless seconds == 60

    @events << [:sleep, seconds]
    @now += seconds
  end

  def workload_snapshot
    @events << :snapshot
    @counters.dup
  end

  def workload_progress(baseline)
    @progress_calls += 1
    raise SyntheticProgressFailure, 'synthetic progress failure' if @progress_calls == @fail_progress_at
    raise 'progress baseline changed' unless baseline == @counters

    @events << :progress
    @counters = @counters.transform_values { |value| value + 1 }
  end

  def load_set(progress_log)
    @events << :forward
    before = workload_snapshot
    after = workload_progress(before)
    progress_log << {release: '6.12.113.1', before: before, after: after}
    [{release: '6.12.113.1', enabled: 1, transition: 0, replace: 0}]
  end

  def reverse_set(progress_log)
    @events << :reverse
    before = workload_snapshot
    after = workload_progress(before)
    progress_log << {
      removedRelease: '6.12.113.1',
      release: '6.12.113',
      before: before,
      after: after,
    }
    [{removedRelease: '6.12.113.1', release: '6.12.113'}]
  end
end

class FakeMachine
  def initialize(events)
    @events = events
  end

  def succeeds(command, timeout:)
    case command
    when 'livepatch-generic-workload start'
      raise 'start timeout changed' unless timeout == 30

      @events << :start
      ['', '']
    when 'livepatch-generic-workload cleanup'
      raise 'cleanup timeout changed' unless timeout == 60

      @events << :cleanup
      ['', JSON.generate('cleanupComplete' => true)]
    else
      raise "unexpected machine command: #{command}"
    end
  end
end

settings = {
  'evidenceClass' => 'development-short',
  'dwellSeconds' => 300,
  'developmentDwellSeconds' => 300,
  'releaseDwellSeconds' => 1800,
  'checkpointSeconds' => 60,
}
consumer = AgedConsumer.new
result = consumer.run_workload_transition(settings)
aging = result.fetch(:aging)
raise 'aging evidence class changed' unless aging.fetch(:evidenceClass) == 'development-short'
raise 'aging required duration changed' unless aging.fetch(:requiredSeconds) == 300
raise 'aging observed duration changed' unless aging.fetch(:observedSeconds) == 300
raise 'aging policy changed' unless aging.values_at(
  :developmentDwellSeconds, :releaseDwellSeconds, :checkpointSeconds
) == [300, 1800, 60]
raise 'aging checkpoint count changed' unless aging.fetch(:checkpoints).length == 5
raise 'aging elapsed checkpoints changed' unless aging.fetch(:checkpoints).map {
  |checkpoint| checkpoint.fetch(:elapsedSeconds)
} == [60, 120, 180, 240, 300]
aging.fetch(:checkpoints).each do |checkpoint|
  WORKLOAD_DIMENSIONS.each do |dimension|
    raise "aging counter did not progress: #{dimension}" unless
      checkpoint.fetch(:after).fetch(dimension) > checkpoint.fetch(:before).fetch(dimension)
  end
end
raise 'forward observation changed' unless result.fetch(:forward).length == 1
raise 'reverse observation changed' unless result.fetch(:reverse).length == 1
raise 'busy cleanup was not complete' unless result.dig(:busy, :cleanupComplete) == true
raise 'workload did not start first' unless consumer.events.first == :start
raise 'aging did not precede forward convergence' unless
  consumer.events.rindex([:sleep, 60]) < consumer.events.index(:forward)
raise 'forward/reverse order changed' unless consumer.events.index(:forward) < consumer.events.index(:reverse)
raise 'cleanup did not run last' unless consumer.events.last == :cleanup

failing = AgedConsumer.new(fail_progress_at: 2)
begin
  failing.run_workload_transition(settings)
  raise 'aged helper failure unexpectedly succeeded'
rescue SyntheticProgressFailure
  raise 'cleanup did not run after helper failure' unless failing.events.last == :cleanup
  raise 'forward convergence ran after helper failure' if failing.events.include?(:forward)
end

puts 'generic aged-transition helper and consumer matrix passed'
RUBY
} >"$work/aging-method-matrix.rb"

"$ruby" -c "$work/aging-method-matrix.rb" >/dev/null
"$ruby" "$work/aging-method-matrix.rb"

make_marker() {
  local row_id=$1
  local profile_id=$2
  local role=$3
  local output=$4

  jq -cn \
    --arg rowId "$row_id" \
    --arg profileId "$profile_id" \
    --arg role "$role" \
    --argjson dimensions "$dimensions" \
    --argjson one "$counters_one" \
    --argjson two "$counters_two" \
    --argjson three "$counters_three" '
    def counters($value): {
      cpu: $value,
      scheduler: $value,
      forkExec: $value,
      cgroupMigration: $value,
      loopbackNetwork: $value,
      filesystemIntegrity: $value
    };
    {
      schemaVersion: 1,
      contract: "generic-livepatch-safety-v1",
      rowId: $rowId,
      setId: "6.12.113.1",
      profileId: $profileId,
      role: $role,
      platform: {
        id: "amd",
        architecture: "x86_64",
        cpuVendor: "AuthenticAMD",
        hypervisorFlag: true,
        hypervisorVendor: "KVM",
        admitted: true
      },
      members: ["6.12.113.1"],
      forward: [{release: "6.12.113.1", enabled: 1, transition: 0, replace: 0}],
      reverse: [{removedRelease: "6.12.113.1", release: "6.12.113"}],
      busy: (
        if $role == "busy-transition" or $role == "aged-transition" then {
          dimensions: $dimensions,
          initial: $one,
          forwardProgress: [{
            release: "6.12.113.1",
            before: (if $role == "aged-transition" then counters(6) else $one end),
            after: (if $role == "aged-transition" then counters(7) else $two end)
          }],
          reverseProgress: [{
            removedRelease: "6.12.113.1",
            release: "6.12.113",
            before: (if $role == "aged-transition" then counters(7) else $two end),
            after: (if $role == "aged-transition" then counters(8) else $three end)
          }],
          final: (if $role == "aged-transition" then counters(8) else $three end),
          cleanupComplete: true
        } else null end
      ),
      aging: (
        if $role == "aged-transition" then {
          evidenceClass: "development-short",
          developmentDwellSeconds: 300,
          releaseDwellSeconds: 1800,
          requiredSeconds: 300,
          observedSeconds: 300,
          checkpointSeconds: 60,
          checkpoints: [
            {elapsedSeconds: 60, before: counters(1), after: counters(2)},
            {elapsedSeconds: 120, before: counters(2), after: counters(3)},
            {elapsedSeconds: 180, before: counters(3), after: counters(4)},
            {elapsedSeconds: 240, before: counters(4), after: counters(5)},
            {elapsedSeconds: 300, before: counters(5), after: counters(6)}
          ]
        } else null end
      ),
      failureRecovery: (
        if $role == "failure-recovery" then {
          duplicateInsertionRefused: true,
          enabledRemovalRefused: true,
          tipUnchangedAfterDuplicate: true,
          tipUnchangedAfterRemoval: true,
          predecessorRestored: true
        } else null end
      ),
      kernelHealth: {clean: true, fatalNoiseCount: 0}
    }
  ' >"$output"
}

make_marker generic-lifecycle-amd set/vendor-lifecycle lifecycle "$work/lifecycle.json"
make_marker generic-busy-amd set/vendor-busy-transition busy-transition "$work/busy.json"
make_marker generic-failure-amd set/vendor-failure-recovery failure-recovery "$work/failure.json"
make_marker generic-aged-amd set/vendor-aged-transition aged-transition "$work/aged.json"

jq -c '
  def counters($value): {
    cpu: $value,
    scheduler: $value,
    forkExec: $value,
    cgroupMigration: $value,
    loopbackNetwork: $value,
    filesystemIntegrity: $value
  };
  .aging.evidenceClass = "release"
  | .aging.requiredSeconds = 1800
  | .aging.observedSeconds = 1800
  | .aging.checkpoints = [
      range(1; 31) as $checkpoint
      | {
          elapsedSeconds: ($checkpoint * 60),
          before: counters($checkpoint),
          after: counters($checkpoint + 1)
        }
    ]
  | .busy.forwardProgress[0].before = counters(31)
  | .busy.forwardProgress[0].after = counters(32)
  | .busy.reverseProgress[0].before = counters(32)
  | .busy.reverseProgress[0].after = counters(33)
  | .busy.final = counters(33)
' "$work/aged.json" >"$work/aged-release.json"

summary_positive='[2026-11-15 11:11:30 +0100] 1 tests successful'
summary_negative='[2026-11-15 03:11:30 -0700] 1 tests successful'

run_validator() {
  local label=$1
  local row_id=$2
  local marker=$3
  local runner_status=$4
  local summary=$5
  local extra=${6-}
  local copies=${7-1}
  local summary_copies=${8-1}
  local semantic_extra=${9-}
  local plan=${10-$work/plan.json}
  local state="$work/case-$label"
  local result_state="$state/os-test-generic"

  mkdir -p "$result_state"
  printf '%s\n' "$runner_status" >"$state/runner.status"
  : >"$state/test.log"
  : >"$result_state/test-runner.log"
  for ((index = 0; index < summary_copies; index++)); do
    [[ -z "$summary" ]] || printf '%s\n' "$summary" >>"$state/test.log"
  done
  for ((index = 0; index < copies; index++)); do
    printf 'VPSADMINOS_LIVEPATCH_GENERIC_RESULT %s\n' \
      "$(cat "$marker")" >>"$result_state/test-runner.log"
  done
  [[ -z "$extra" ]] || printf '%s\n' "$extra" >>"$state/test.log"
  [[ -z "$semantic_extra" ]] || \
    printf '%s\n' "$semantic_extra" >>"$result_state/test-runner.log"

  "$validator" \
    --plan "$plan" \
    --capture "$work/capture.json" \
    --row-id "$row_id" \
    --state-dir "$state" \
    --runner-log "$state/test.log" \
    --semantic-log "$result_state/test-runner.log" \
    --runner-status "$runner_status" \
    --output "$state/result.json"
}

expect_accept() {
  local label=$1
  local row_id=$2
  local marker=$3
  local summary=${4-$summary_positive}
  local plan=${5-$work/plan.json}
  run_validator "$label" "$row_id" "$marker" 0 "$summary" '' 1 1 '' "$plan"
  jq -e --arg rowId "$row_id" '
    .schemaVersion == 1
    and .rowId == $rowId
    and .accepted == true
    and .runnerStatus == 0
    and .validator.id == "builtin/generic-livepatch-safety-v1"
    and .validator.status == "accepted"
    and .semantic.contract == "generic-livepatch-safety-v1"
  ' "$work/case-$label/result.json" >/dev/null
}

expect_aged_plan_refuse() {
  local label=$1
  local plan=$2
  local marker=$3
  if run_validator "$label" generic-aged-amd "$marker" 0 "$summary_positive" \
    '' 1 1 '' "$plan" >"$work/$label.stdout" 2>"$work/$label.stderr"; then
    echo "aged plan/marker mismatch unexpectedly succeeded: $label" >&2
    exit 1
  fi
  [[ ! -e "$work/case-$label/result.json" ]]
}

expect_refuse() {
  local label=$1
  shift
  if run_validator "$label" "$@" >"$work/$label.stdout" 2>"$work/$label.stderr"; then
    echo "refusal case unexpectedly succeeded: $label" >&2
    exit 1
  fi
  [[ ! -e "$work/case-$label/result.json" ]]
}

expect_accept lifecycle generic-lifecycle-amd "$work/lifecycle.json" "$summary_positive"
expect_accept busy generic-busy-amd "$work/busy.json" "$summary_negative"
expect_accept failure generic-failure-amd "$work/failure.json" "$summary_positive"
expect_accept aged generic-aged-amd "$work/aged.json" "$summary_negative"
expect_accept aged-release generic-aged-amd "$work/aged-release.json" \
  "$summary_positive" "$work/plan-release.json"
expect_aged_plan_refuse aged-release-with-development-plan \
  "$work/plan.json" "$work/aged-release.json"
expect_aged_plan_refuse aged-development-with-release-plan \
  "$work/plan-release.json" "$work/aged.json"

jq -c '.role = "failure-recovery"' "$work/lifecycle.json" >"$work/wrong-role.json"
jq -c '.platform.id = "intel"' "$work/lifecycle.json" >"$work/wrong-platform.json"
jq -c '.busy = null' "$work/busy.json" >"$work/missing-busy.json"
jq -c '.busy.forwardProgress[0].after.cpu = 1' "$work/busy.json" >"$work/stalled-counter.json"
jq -c '.busy.cleanupComplete = false' "$work/busy.json" >"$work/missing-cleanup.json"
jq -c '.failureRecovery.enabledRemovalRefused = false' "$work/failure.json" >"$work/missing-refusal.json"
jq -c '.kernelHealth.fatalNoiseCount = 1' "$work/lifecycle.json" >"$work/unclean-marker.json"
jq -c '.aging.observedSeconds = 299' "$work/aged.json" >"$work/aged-under-duration.json"
jq -c '.aging.checkpoints[2].after.cpu = .aging.checkpoints[2].before.cpu' \
  "$work/aged.json" >"$work/aged-stalled.json"
jq -c '.aging.checkpoints[2].elapsedSeconds = 120' \
  "$work/aged.json" >"$work/aged-nonmonotonic.json"
jq -c '.aging.checkpoints[1].after.scheduler = "invalid"' \
  "$work/aged.json" >"$work/aged-malformed-checkpoint.json"
jq -c '.aging.evidenceClass = "release"' \
  "$work/aged.json" >"$work/aged-settings-mismatch.json"
jq -c '.busy.cleanupComplete = false' "$work/aged.json" >"$work/aged-missing-cleanup.json"
jq -c '.kernelHealth.fatalNoiseCount = 1' "$work/aged.json" >"$work/aged-unclean.json"
printf '{invalid-json\n' >"$work/malformed.json"
printf '{}\n' >"$work/empty.json"

expect_refuse wrong-role generic-lifecycle-amd "$work/wrong-role.json" 0 "$summary_positive"
expect_refuse wrong-platform generic-lifecycle-amd "$work/wrong-platform.json" 0 "$summary_positive"
expect_refuse missing-busy generic-busy-amd "$work/missing-busy.json" 0 "$summary_positive"
expect_refuse stalled-counter generic-busy-amd "$work/stalled-counter.json" 0 "$summary_positive"
expect_refuse missing-cleanup generic-busy-amd "$work/missing-cleanup.json" 0 "$summary_positive"
expect_refuse missing-refusal generic-failure-amd "$work/missing-refusal.json" 0 "$summary_positive"
expect_refuse unclean-marker generic-lifecycle-amd "$work/unclean-marker.json" 0 "$summary_positive"
expect_refuse malformed generic-lifecycle-amd "$work/malformed.json" 0 "$summary_positive"
expect_refuse duplicate generic-lifecycle-amd "$work/lifecycle.json" 0 "$summary_positive" '' 2
expect_refuse nonzero-runner generic-lifecycle-amd "$work/lifecycle.json" 1 "$summary_positive"
expect_refuse missing-summary generic-lifecycle-amd "$work/lifecycle.json" 0 ''
expect_refuse unprefixed-summary generic-lifecycle-amd "$work/lifecycle.json" 0 '1 tests successful'
expect_refuse malformed-summary generic-lifecycle-amd "$work/lifecycle.json" 0 \
  '[2026-11-15 11:11 +0100] 1 tests successful'
expect_refuse wrong-count-summary generic-lifecycle-amd "$work/lifecycle.json" 0 \
  '[2026-11-15 11:11:30 +0100] 2 tests successful'
expect_refuse duplicate-summary generic-lifecycle-amd "$work/lifecycle.json" 0 \
  "$summary_positive" '' 1 2
expect_refuse embedded-suffix-summary generic-lifecycle-amd "$work/lifecycle.json" 0 \
  '[2026-11-15 11:11:30 +0100] 1 tests successful suffix'
expect_refuse fatal-noise generic-lifecycle-amd "$work/lifecycle.json" 0 \
  "$summary_positive" 'kernel BUG at synthetic.c:1'
expect_refuse child-fatal-noise generic-lifecycle-amd "$work/lifecycle.json" 0 \
  "$summary_positive" '' 1 1 'kernel BUG at synthetic.c:1'
expect_refuse aged-under-duration generic-aged-amd "$work/aged-under-duration.json" 0 "$summary_positive"
expect_refuse aged-stalled generic-aged-amd "$work/aged-stalled.json" 0 "$summary_positive"
expect_refuse aged-nonmonotonic generic-aged-amd "$work/aged-nonmonotonic.json" 0 "$summary_positive"
expect_refuse aged-malformed-checkpoint generic-aged-amd "$work/aged-malformed-checkpoint.json" 0 "$summary_positive"
expect_refuse aged-settings-mismatch generic-aged-amd "$work/aged-settings-mismatch.json" 0 "$summary_positive"
expect_refuse aged-missing-cleanup generic-aged-amd "$work/aged-missing-cleanup.json" 0 "$summary_positive"
expect_refuse aged-unclean generic-aged-amd "$work/aged-unclean.json" 0 "$summary_positive"

mkdir "$work/case-smoke"
mkdir "$work/case-smoke/os-test-generic"
printf '0\n' >"$work/case-smoke/runner.status"
printf '%s\n' "$summary_positive" >"$work/case-smoke/test.log"
: >"$work/case-smoke/os-test-generic/test-runner.log"
if "$validator" \
  --plan "$work/plan.json" \
  --capture "$work/capture.json" \
  --row-id generic-lifecycle-amd \
  --state-dir "$work/case-smoke" \
  --runner-log "$work/case-smoke/test.log" \
  --semantic-log "$work/case-smoke/os-test-generic/test-runner.log" \
  --runner-status 0 \
  --output "$work/case-smoke/result.json" \
  >"$work/smoke.stdout" 2>"$work/smoke.stderr"; then
  echo "exit-zero smoke case unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -e "$work/case-smoke/result.json" ]]

mkdir "$work/results-full"
for mapping in \
  "generic-aged-amd:aged" \
  "generic-lifecycle-amd:lifecycle" \
  "generic-busy-amd:busy" \
  "generic-failure-amd:failure"; do
  row_id=${mapping%%:*}
  label=${mapping#*:}
  mkdir "$work/results-full/$row_id"
  cp "$work/case-$label/result.json" "$work/results-full/$row_id/result.json"
done

run_campaign() {
  local label=$1
  local directory=$2
  "$verifier" \
    --plan "$work/plan.json" \
    --results-dir "$directory" \
    --output "$work/$label.json"
}

run_campaign full "$work/results-full"
jq -e '.schemaVersion == 1 and .accepted == true and .plannedRows == 4 and (.receipts | length) == 4' \
  "$work/full.json" >/dev/null

cp -a "$work/results-full" "$work/results-missing"
rm "$work/results-missing/generic-busy-amd/result.json"
if run_campaign missing "$work/results-missing"; then
  echo "missing campaign receipt unexpectedly succeeded" >&2
  exit 1
fi

cp -a "$work/results-full" "$work/results-failed"
jq '.accepted = false | .validator.status = "rejected"' \
  "$work/results-failed/generic-busy-amd/result.json" >"$work/failed-result.json"
mv "$work/failed-result.json" "$work/results-failed/generic-busy-amd/result.json"
if run_campaign failed "$work/results-failed"; then
  echo "failed campaign receipt unexpectedly succeeded" >&2
  exit 1
fi

cp -a "$work/results-missing" "$work/results-canceled"
if run_campaign canceled "$work/results-canceled"; then
  echo "canceled campaign receipt unexpectedly succeeded" >&2
  exit 1
fi

cp -a "$work/results-full" "$work/results-duplicate"
mkdir "$work/results-duplicate/duplicate"
cp "$work/results-full/generic-busy-amd/result.json" "$work/results-duplicate/duplicate/result.json"
if run_campaign duplicate "$work/results-duplicate"; then
  echo "duplicate campaign receipt unexpectedly succeeded" >&2
  exit 1
fi

cp -a "$work/results-full" "$work/results-unplanned"
jq '.rowId = "unplanned-row" | .semantic.rowId = "unplanned-row"' \
  "$work/results-unplanned/generic-busy-amd/result.json" >"$work/unplanned-result.json"
mv "$work/unplanned-result.json" "$work/results-unplanned/generic-busy-amd/result.json"
if run_campaign unplanned "$work/results-unplanned"; then
  echo "unplanned campaign receipt unexpectedly succeeded" >&2
  exit 1
fi

cp -a "$work/results-full" "$work/results-no-semantic"
jq 'del(.semantic)' "$work/results-no-semantic/generic-busy-amd/result.json" \
  >"$work/no-semantic-result.json"
mv "$work/no-semantic-result.json" "$work/results-no-semantic/generic-busy-amd/result.json"
if run_campaign no-semantic "$work/results-no-semantic"; then
  echo "generic result without semantic evidence unexpectedly succeeded" >&2
  exit 1
fi

if [[ -n "$nfs_validator$nfs_oracle_script$nfs_plan$nfs_capture" ]]; then
  [[ -x "$nfs_validator" ]]
  [[ -f "$nfs_oracle_script" && ! -L "$nfs_oracle_script" ]]
  [[ -f "$nfs_plan" && ! -L "$nfs_plan" ]]
  [[ -f "$nfs_capture" && ! -L "$nfs_capture" ]]
  jq -e '
    . as $plan
    | .sets[0] as $set
    | .counts.catalogReleases == ($plan.releases | length)
    and .counts.normalizedReleases == ($plan.releases | length)
    and .counts.plannedMembers == ($set.members | length)
    and .counts.activeOracles == ($set.oracleIds | length)
    and .counts.coverageTuples == ($plan.coverage | length)
    and .counts.plannedRows == ($plan.rows | length)
    and .counts.matrixRows == ($plan.matrix.include | length)
    and ([.rows[] | select(.role == "aged-transition")] | length) == 2
    and ([.rows[] | select(.role == "aged-transition") | .aging] | all(
      . == {
        evidenceClass: "release",
        dwellSeconds: 1800,
        developmentDwellSeconds: 300,
        releaseDwellSeconds: 1800,
        checkpointSeconds: 60
      }
    ))
  ' "$nfs_plan" >/dev/null

  extract_method() {
    local begin=$1
    local end=$2
    local source=$3
    local output=$4

    [[ $(grep -F -c -- "$begin" "$source") -eq 1 ]]
    [[ $(grep -F -c -- "$end" "$source") -eq 1 ]]
    awk -v begin="$begin" -v end="$end" '
      index($0, begin) { capture = 1; next }
      index($0, end) { capture = 0 }
      capture { print }
    ' "$source" >"$output"
    [[ -s "$output" ]]
  }

  extract_method F9_GENERIC_COMPLETED_DISABLE_BEGIN F9_GENERIC_COMPLETED_DISABLE_END \
    "$generic_template" "$work/generic-completed-disable.rb"
  extract_method F9_GENERIC_REMOVAL_WAIT_BEGIN F9_GENERIC_REMOVAL_WAIT_END \
    "$generic_template" "$work/generic-removal-wait.rb"
  extract_method F9_GENERIC_REVERSE_SET_BEGIN F9_GENERIC_REVERSE_SET_END \
    "$generic_template" "$work/generic-reverse-set.rb"
  extract_method F9_NFS_COMPLETED_DISABLE_BEGIN F9_NFS_COMPLETED_DISABLE_END \
    "$nfs_oracle_script" "$work/nfs-completed-disable.rb"
  extract_method F9_NFS_REVERSE_BOUNDARY_BEGIN F9_NFS_REVERSE_BOUNDARY_END \
    "$nfs_oracle_script" "$work/nfs-reverse-boundary.rb"
  extract_method D7_NFS_STACK_LIFECYCLE_BEGIN D7_NFS_STACK_LIFECYCLE_END \
    "$nfs_oracle_script" "$work/nfs-stack-lifecycle.rb"

  {
    cat <<'RUBY'
require 'fileutils'
require 'open3'
require 'pathname'
require 'shellwords'
require 'tmpdir'

class PredicateMachine
  attr_reader :events, :module_name, :module_path, :module_root, :patch_path

  def initialize(root, module_name)
    @root = Pathname(root)
    @module_name = module_name
    @patch_path = @root.join('patch')
    @module_root = @root.join('modules')
    @module_path = @module_root.join(module_name)
    @events = []
  end

  def configure(state)
    FileUtils.rm_rf(patch_path)
    FileUtils.rm_rf(module_root)
    FileUtils.mkdir_p(module_root)
    FileUtils.mkdir_p(module_path) unless state == :premature_module_loss

    case state
    when :positive, :premature_module_loss
      nil
    when :active
      write_patch_state('1', '0', '0')
    when :pending
      write_patch_state('0', '1', '0')
    when :disabled_extant
      write_patch_state('0', '0', '0')
    when :malformed
      write_patch_state('invalid', 'invalid', 'invalid')
    when :missing_files
      FileUtils.mkdir_p(patch_path)
    else
      raise "unsupported fixture state: #{state}"
    end
    events.clear
  end

  def succeeds(command, timeout: nil)
    raise 'unexpected succeeds timeout' unless [60, nil].include?(timeout)

    if command.include?('echo 0 >')
      raise 'disable write did not target the exact patch' unless command.include?(patch_path.to_s)
      raise 'disable write lost the module prematurely' unless module_path.directory?
      events << :disable
      FileUtils.rm_rf(patch_path)
    elsif command.start_with?('rmmod ')
      raise 'rmmod ran before completed-disable convergence' unless !patch_path.exist? && module_path.directory?
      events << :rmmod
      FileUtils.rm_rf(module_path)
    elsif command.include?('uname -r')
      raise 'release check ran before full removal' if patch_path.exist? || module_path.exist?
      events << :release
    else
      raise "unexpected succeeds command: #{command}"
    end
    ['', '']
  end

  def wait_until_succeeds(command, timeout:)
    raise 'unexpected wait timeout' unless timeout == 180
    event =
      if command.include?('test -d /sys/module/')
        :completed_disable_wait
      elsif command.include?('test ! -d /sys/module/')
        :removed_wait
      else
        raise "unexpected wait command: #{command}"
      end
    events << event
    translated = command.gsub('/sys/module/', "#{module_root}/")
    _stdout, stderr, status = Open3.capture3(ENV.fetch('F9_TEST_BASH'), '-c', translated)
    raise "wait predicate refused: #{stderr}" unless status.success?
    ['', '']
  end

  private

  def write_patch_state(enabled, transition, replace)
    FileUtils.mkdir_p(patch_path)
    {
      'enabled' => enabled,
      'transition' => transition,
      'replace' => replace,
    }.each do |name, value|
      patch_path.join(name).write("#{value}\n")
    end
  end
end

class GenericConsumer
  def initialize(machine)
    @machine = machine
    @set = {'kernelVersion' => '6.12.113'}
    @captured_set = {
      'members' => [{
        'release' => '6.12.113.1',
        'identity' => {'moduleName' => machine.module_name},
      }],
    }
  end

  def machine
    @machine
  end

  def patch_dir(_module_name)
    machine.patch_path.to_s
  end

  def shell(value)
    Shellwords.escape(value)
  end
RUBY
    cat "$work/generic-completed-disable.rb"
    cat "$work/generic-removal-wait.rb"
    cat "$work/generic-reverse-set.rb"
    cat <<'RUBY'
end

class NfsConsumer
RUBY
    cat "$work/nfs-completed-disable.rb"
    cat "$work/nfs-stack-lifecycle.rb"
    cat <<'RUBY'
end

class NfsStackMachine
  attr_reader :events

  def initialize
    @events = []
  end

  def succeeds(command, timeout: nil)
    raise 'unexpected NFS succeeds timeout' unless [60, nil].include?(timeout)

    case command
    when /\Ainsmod /
      events << [:insmod, Shellwords.split(command).last]
    when /echo 0 > \/sys\/kernel\/livepatch\/([^\/]+)\/enabled/
      events << [:disable, Regexp.last_match(1)]
    when /\Armmod /
      events << [:rmmod, Shellwords.split(command).last]
    when /uname -r/
      events << [:release, Shellwords.split(command).last]
    else
      raise "unexpected NFS succeeds command: #{command}"
    end
    ['', '']
  end

  def wait_until_succeeds(command, timeout:)
    raise 'unexpected NFS wait timeout' unless timeout == 180

    event =
      if command.include?('enabled')
        [:forward_converged, command.match(%r{/sys/kernel/livepatch/([^/ ]+)})&.captures&.first]
      elsif command.include?('test -d /sys/module/')
        [:completed_disable, command.match(%r{/sys/module/([^ ]+)})&.captures&.first]
      elsif command.include?('test ! -d /sys/module/')
        [:removed, command.match(%r{/sys/module/([^ ]+)})&.captures&.first]
      else
        raise "unexpected NFS wait command: #{command}"
      end
    raise "NFS wait command did not identify a module: #{command}" if event.last.nil?

    events << event
    ['', '']
  end
end

Dir.mktmpdir('livepatch-reverse-convergence-') do |root|
  module_name = 'lp_612113_1_test'
  machine = PredicateMachine.new(root, module_name)
  generic = GenericConsumer.new(machine)
  nfs = NfsConsumer.new

  {
    generic: -> { generic.wait_completed_disable(module_name) },
    nfs: -> { nfs.wait_nfs_completed_disable(machine, machine.patch_path.to_s, module_name) },
  }.each do |consumer, check|
    machine.configure(:positive)
    check.call

    %i[active pending disabled_extant malformed missing_files premature_module_loss].each do |state|
      machine.configure(state)
      refused = false
      begin
        check.call
      rescue RuntimeError
        refused = true
      end
      raise "#{consumer} unexpectedly accepted #{state}" unless refused
    end
  end

  machine.configure(:active)
  observations = generic.reverse_set
  expected_events = %i[disable completed_disable_wait rmmod removed_wait release]
  raise "generic reverse order mismatch: #{machine.events.inspect}" unless machine.events == expected_events
  expected_observations = [{removedRelease: '6.12.113.1', release: '6.12.113'}]
  raise "generic reverse observation mismatch" unless observations == expected_observations
end

nfs = NfsConsumer.new
one_member = [{
  release: '6.12.113.1',
  module_path: '/nix/store/synthetic-one.ko',
  module_name: 'lp_612113_1_one',
  patch_dir: '/sys/kernel/livepatch/lp_612113_1_one',
}]
two_members = one_member + [{
  release: '6.12.113.2',
  module_path: '/nix/store/synthetic-two.ko',
  module_name: 'lp_612113_2_two',
  patch_dir: '/sys/kernel/livepatch/lp_612113_2_two',
}]

[one_member, two_members].each do |members|
  machine = NfsStackMachine.new
  forward = nfs.load_nfs_set(machine, members)
  reverse = nfs.reverse_nfs_set(machine, members, '6.12.113')
  expected_forward = members.map do |member|
    {release: member.fetch(:release), enabled: 1, transition: 0, replace: 0}
  end
  expected_reverse = members.each_index.reverse_each.map do |index|
    {
      removedRelease: members.fetch(index).fetch(:release),
      release: index.zero? ? '6.12.113' : members.fetch(index - 1).fetch(:release),
      moduleRemoved: true,
    }
  end
  expected_events = members.flat_map do |member|
    [
      [:insmod, member.fetch(:module_path)],
      [:forward_converged, member.fetch(:module_name)],
      [:release, member.fetch(:release)],
    ]
  end
  expected_events += members.each_index.reverse_each.flat_map do |index|
    member = members.fetch(index)
    predecessor = index.zero? ? '6.12.113' : members.fetch(index - 1).fetch(:release)
    [
      [:disable, member.fetch(:module_name)],
      [:completed_disable, member.fetch(:module_name)],
      [:rmmod, member.fetch(:module_name)],
      [:removed, member.fetch(:module_name)],
      [:release, predecessor],
    ]
  end
  raise 'NFS forward observations mismatch' unless forward == expected_forward
  raise 'NFS reverse observations mismatch' unless reverse == expected_reverse
  raise "NFS stack lifecycle order mismatch: #{machine.events.inspect}" unless
    machine.events == expected_events
end

nfs_boundary = File.binread(ARGV.fetch(0))
positions = [
  nfs_boundary.index('echo 0 >'),
  nfs_boundary.index('wait_nfs_completed_disable'),
  nfs_boundary.index('rmmod'),
  nfs_boundary.index('test ! -d #{Shellwords.escape(patch_dir)} && test ! -d /sys/module'),
  nfs_boundary.index('uname -r'),
]
raise 'NFS reverse boundary is incomplete' if positions.any?(&:nil?)
raise 'NFS reverse boundary order mismatch' unless positions == positions.sort && positions.uniq.length == positions.length

puts 'generic and NFS one/two-member stack convergence matrix passed'
RUBY
  } >"$work/reverse-convergence-matrix.rb"

  F9_TEST_BASH=$BASH "$ruby" -c "$work/reverse-convergence-matrix.rb" >/dev/null
  F9_TEST_BASH=$BASH "$ruby" "$work/reverse-convergence-matrix.rb" \
    "$work/nfs-reverse-boundary.rb"

  awk '
    /F6_NFS_CAPTURE_RELATION_BEGIN/ { capture = 1; next }
    /F6_NFS_CAPTURE_RELATION_END/ { capture = 0 }
    capture { print }
  ' "$nfs_oracle_script" >"$work/nfs-capture-relation-method.rb"
  [[ -s "$work/nfs-capture-relation-method.rb" ]]

  {
    printf 'require "json"\n\nclass NfsCaptureRelation\n'
    cat "$work/nfs-capture-relation-method.rb"
    cat <<'RUBY'
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def refuse(label)
  yield
rescue KeyError, RuntimeError
  return
else
  raise "NFS capture relation unexpectedly accepted #{label}"
end

plan = JSON.parse(File.binread(ARGV.fetch(0)))
capture = JSON.parse(File.binread(ARGV.fetch(1)))
planned_set = plan.fetch('sets').fetch(0)
captured_set = capture.fetch('sets').fetch(0)
relation = NfsCaptureRelation.new
relation.validate_nfs_capture_relation(planned_set, captured_set)

missing_target = deep_copy(planned_set)
missing_target.fetch('members').fetch(0).delete('kernelVersion')
refuse('missing planned member target') do
  relation.validate_nfs_capture_relation(missing_target, captured_set)
end

mismatched_target = deep_copy(planned_set)
mismatched_target.fetch('members').fetch(0)['kernelVersion'] = '6.12.114'
refuse('mismatched planned member target') do
  relation.validate_nfs_capture_relation(mismatched_target, captured_set)
end

mismatched_release = deep_copy(captured_set)
mismatched_release.fetch('members').fetch(0)['release'] = '6.12.113.2'
refuse('capture/plan release mismatch') do
  relation.validate_nfs_capture_relation(planned_set, mismatched_release)
end

two_member_plan = deep_copy(planned_set)
two_member_plan['id'] = '6.12.113.2'
two_member_plan['tipRelease'] = '6.12.113.2'
two_member_plan.fetch('members') << deep_copy(two_member_plan.fetch('members').fetch(0)).merge(
  'release' => '6.12.113.2',
  'releaseOrdinal' => 2,
  'predecessorRelease' => '6.12.113.1',
)
two_member_capture = deep_copy(captured_set)
two_member_capture.fetch('members') << deep_copy(two_member_capture.fetch('members').fetch(0)).merge(
  'release' => '6.12.113.2',
)
relation.validate_nfs_capture_relation(two_member_plan, two_member_capture)

missing_capture = deep_copy(two_member_capture)
missing_capture.fetch('members').pop
refuse('missing captured member') do
  relation.validate_nfs_capture_relation(two_member_plan, missing_capture)
end

reordered_capture = deep_copy(two_member_capture)
reordered_capture['members'].reverse!
refuse('reordered members') do
  relation.validate_nfs_capture_relation(two_member_plan, reordered_capture)
end

extra_capture = deep_copy(two_member_capture)
extra_capture.fetch('members') << deep_copy(extra_capture.fetch('members').fetch(0)).merge(
  'release' => '6.12.113.3',
)
refuse('extra captured member') do
  relation.validate_nfs_capture_relation(two_member_plan, extra_capture)
end

puts 'NFS livepatch capture relation passed'
RUBY
  } >"$work/nfs-capture-relation.rb"

  "$ruby" "$work/nfs-capture-relation.rb" "$nfs_plan" "$nfs_capture"

  "$ruby" -c "$nfs_oracle_script" >/dev/null

  jq '
    . as $source
    | ($source.rows | map(select(
        .scope == "fix"
        and .oracleIds == ["nfs-client-operation-safety"]
      ))) as $nfsRows
    | ($nfsRows | map(
        .setId = "6.12.113.2"
        | .rowId = (
            "6.12.113.2--fix-synthetic-successor-synthetic-successor-oracle--"
            + .platformId
          )
        | .profileId = "fix/synthetic-successor/synthetic-successor-oracle"
        | .role = "fixed-path"
        | .oracleIds = ["synthetic-successor-oracle"]
        | .oracleShard = "synthetic-successor-oracle"
        | .testAdapter
          = "os/livepatches/batches/6.12.113/2/qualification/helpers/synthetic-successor.nix"
        | .validator
          = "os/livepatches/batches/6.12.113/2/qualification/validators/synthetic-successor.sh"
      )) as $successorRows
    | .releases += [
        (.releases[0]
          | .release = "6.12.113.2"
          | .releaseOrdinal = 2)
      ]
    | .sets[0].id = "6.12.113.2"
    | .sets[0].tipRelease = "6.12.113.2"
    | .sets[0].members += [
        (.sets[0].members[0]
          | .release = "6.12.113.2"
          | .releaseOrdinal = 2
          | .predecessorRelease = "6.12.113.1"
          | .producerAttr = "livepatch-6.12.113.2"
          | .fixIds = ["synthetic-successor"]
          | .oracleIds = ["synthetic-successor-oracle"])
      ]
    | .sets[0].oracleIds += ["synthetic-successor-oracle"]
    | .sets[0].oracles += [
        (.sets[0].oracles[0]
          | .fixId = "synthetic-successor"
          | .id = "synthetic-successor-oracle"
          | .role = "fixed-path"
          | .testAdapter
            = "os/livepatches/batches/6.12.113/2/qualification/helpers/synthetic-successor.nix"
          | .validator
            = "os/livepatches/batches/6.12.113/2/qualification/validators/synthetic-successor.sh")
      ]
    | .rows |= map(
        .setId = "6.12.113.2"
        | .rowId |= sub("^6\\.12\\.113\\.1--"; "6.12.113.2--")
      )
    | .rows += $successorRows
    | .coverage |= map(
        .setId = "6.12.113.2"
        | .rowId |= sub("^6\\.12\\.113\\.1--"; "6.12.113.2--")
      )
    | .coverage += ($successorRows | map({
        oracleId: .oracleIds[0],
        platformId,
        profileId,
        rowId,
        setId
      }))
    | .matrix.include |= map(
        .setId = "6.12.113.2"
        | .rowId |= sub("^6\\.12\\.113\\.1--"; "6.12.113.2--")
      )
    | .matrix.include += ($successorRows | map({
        expectedOutcome,
        profileId,
        rowId,
        runnerClass,
        setId,
        timeoutClass
      }))
    | .counts.catalogReleases = (.releases | length)
    | .counts.normalizedReleases = (.releases | length)
    | .counts.plannedMembers = (.sets[0].members | length)
    | .counts.activeOracles = (.sets[0].oracleIds | length)
    | .counts.coverageTuples = (.coverage | length)
    | .counts.plannedRows = (.rows | length)
    | .counts.matrixRows = (.matrix.include | length)
  ' "$nfs_plan" >"$work/nfs-plan-two.json"

  jq '
    .sets[0].id = "6.12.113.2"
    | .sets[0].members += [
        (.sets[0].members[0]
          | .release = "6.12.113.2"
          | .identity.producer
            = "/nix/store/11111111111111111111111111111111-synthetic-producer-2"
          | .identity.module
            = "/nix/store/11111111111111111111111111111111-synthetic-producer-2/synthetic-2.ko"
          | .identity.moduleName = "synthetic_livepatch_2"
          | .identity.moduleSha256
            = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
          | .identity.inputDigest
            = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd")
      ]
    | .counts.plannedMembers = (.sets[0].members | length)
    | .counts.capturedMembers = (.sets[0].members | length)
  ' "$nfs_capture" >"$work/nfs-capture-two.json"

  printf 'NFS rendered one/two-member stack admission passed\n'

  nfs_row=$(jq -cer '[.rows[] | select(
      .scope == "fix"
      and .platformId == "amd"
      and .oracleIds == ["nfs-client-operation-safety"]
    )]
    | if length == 1 then .[0] else error("AMD NFS row is not unique") end' "$nfs_plan")
  nfs_row_id=$(jq -er '.rowId' <<<"$nfs_row")
  nfs_other_row_id=$(jq -er '.rows[] | select(
    .scope == "fix"
    and .platformId == "intel"
    and .oracleIds == ["nfs-client-operation-safety"]
  ) | .rowId' "$nfs_plan")
  nfs_two_row=$(jq -cer '[.rows[] | select(
      .scope == "fix"
      and .platformId == "amd"
      and .oracleIds == ["nfs-client-operation-safety"]
    )]
    | if length == 1 then .[0] else error("two-member AMD NFS row is not unique") end' \
    "$work/nfs-plan-two.json")
  nfs_two_row_id=$(jq -er '.rowId' <<<"$nfs_two_row")

  write_nfs_marker() {
    local plan_file=$1
    local capture_file=$2
    local selected_row=$3
    local output_file=$4
    jq -cn \
      --argjson row "$selected_row" \
      --slurpfile plan "$plan_file" \
      --slurpfile capture "$capture_file" '
      ($plan[0].sets[0].members | map(.release)) as $releases
      | {
        schemaVersion: 1,
        oracleId: "nfs-client-operation-safety",
        platformId: $row.platformId,
        runnerClass: $row.runnerClass,
        rowId: $row.rowId,
        setId: $row.setId,
        nativeRelease: $plan[0].sets[0].kernelVersion,
        tipRelease: $plan[0].sets[0].tipRelease,
        members: ($capture[0].sets[0].members | map({release, identity})),
        workload: {
          mounts: 2,
          freshMounts: 2,
          operations: 1,
          integritySha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        },
        quiescence: {
          mountCreation: true,
          finalUnmount: true,
          shutdownSysfsWrites: true
        },
        forward: ($releases | map({release: ., enabled: 1, transition: 0, replace: 0})),
        reverse: [
          range(($releases | length) - 1; -1; -1) as $index
          | {
              removedRelease: $releases[$index],
              release: (
                if $index == 0 then $plan[0].sets[0].kernelVersion
                else $releases[$index - 1]
                end
              ),
              moduleRemoved: true
            }
        ],
        kernelHealth: "clean"
      }
    ' >"$output_file"
  }

  write_nfs_marker "$nfs_plan" "$nfs_capture" "$nfs_row" "$work/nfs-marker.json"
  write_nfs_marker "$work/nfs-plan-two.json" "$work/nfs-capture-two.json" \
    "$nfs_two_row" "$work/nfs-marker-two.json"

  run_nfs_validator() {
    local label=$1
    local plan_file=$2
    local capture_file=$3
    local selected_row=$4
    local marker_file=$5
    local state="$work/nfs-$label"
    local result_state="$state/os-test-nfs"

    mkdir -p "$result_state"
    printf '0\n' >"$state/runner.status"
    printf '1 tests successful\n' >"$state/test.log"
    {
      printf 'VPSADMINOS_LIVEPATCH_ORACLE_RESULT '
      cat "$marker_file"
      printf '\n'
    } >"$result_state/test-runner.log"
    "$nfs_validator" \
      --plan "$plan_file" \
      --capture "$capture_file" \
      --row-id "$selected_row" \
      --state-dir "$state" \
      --runner-log "$state/test.log" \
      --semantic-log "$result_state/test-runner.log" \
      --runner-status 0 \
      --output "$state/result.json"
  }

  expect_nfs_refuse() {
    local label=$1
    shift
    if run_nfs_validator "$label" "$@" >"$work/nfs-$label.stdout" 2>"$work/nfs-$label.stderr"; then
      echo "NFS validator refusal case unexpectedly succeeded: $label" >&2
      exit 1
    fi
    [[ ! -e "$work/nfs-$label/result.json" ]]
  }

  run_nfs_validator valid "$nfs_plan" "$nfs_capture" "$nfs_row_id" "$work/nfs-marker.json"
  jq -e '
    .schemaVersion == 1
    and .accepted == true
    and .validator.status == "accepted"
    and .validator.members == ["6.12.113.1"]
    and .validator.tipRelease == "6.12.113.1"
  ' \
    "$work/nfs-valid/result.json" >/dev/null
  run_nfs_validator two-member "$work/nfs-plan-two.json" "$work/nfs-capture-two.json" \
    "$nfs_two_row_id" "$work/nfs-marker-two.json"
  jq -e '
    .schemaVersion == 1
    and .accepted == true
    and .validator.status == "accepted"
    and .validator.members == ["6.12.113.1", "6.12.113.2"]
    and .validator.tipRelease == "6.12.113.2"
  ' "$work/nfs-two-member/result.json" >/dev/null

  jq '.sets[0].members[0].kernelVersion = "6.12.114"' "$nfs_plan" >"$work/nfs-plan-target-mismatch.json"
  jq 'del(.sets[0].members[0].kernelVersion)' "$nfs_plan" >"$work/nfs-plan-target-missing.json"
  jq '.sets[0].members[0].release = "6.12.113.2"' "$nfs_capture" >"$work/nfs-capture-release-mismatch.json"
  jq '.sets[0].members |= reverse' \
    "$work/nfs-capture-two.json" >"$work/nfs-capture-two-reordered.json"
  jq 'del(.sets[0].members[1]) | .counts.capturedMembers = 1' \
    "$work/nfs-capture-two.json" >"$work/nfs-capture-two-missing.json"
  jq '
    .sets[0].members += [(.sets[0].members[1] | .release = "6.12.113.3")]
    | .counts.capturedMembers = 3
  ' "$work/nfs-capture-two.json" >"$work/nfs-capture-two-extra.json"
  jq '.members[0].identity.moduleSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "$work/nfs-marker.json" >"$work/nfs-marker-identity-mismatch.json"
  jq '.members |= reverse' \
    "$work/nfs-marker-two.json" >"$work/nfs-marker-two-reordered.json"
  jq '.tipRelease = "6.12.113.1"' \
    "$work/nfs-marker-two.json" >"$work/nfs-marker-two-tip-mismatch.json"
  jq '.reverse |= reverse' \
    "$work/nfs-marker-two.json" >"$work/nfs-marker-two-reverse-mismatch.json"
  jq '.platformId = "intel"' "$work/nfs-marker.json" >"$work/nfs-marker-wrong-platform.json"
  printf '{invalid-json\n' >"$work/nfs-marker-malformed.json"

  expect_nfs_refuse target-mismatch "$work/nfs-plan-target-mismatch.json" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse target-missing "$work/nfs-plan-target-missing.json" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse release-mismatch "$nfs_plan" "$work/nfs-capture-release-mismatch.json" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse two-reordered "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two-reordered.json" "$nfs_two_row_id" "$work/nfs-marker-two.json"
  expect_nfs_refuse two-missing "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two-missing.json" "$nfs_two_row_id" "$work/nfs-marker-two.json"
  expect_nfs_refuse two-extra "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two-extra.json" "$nfs_two_row_id" "$work/nfs-marker-two.json"
  expect_nfs_refuse identity-mismatch "$nfs_plan" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker-identity-mismatch.json"
  expect_nfs_refuse marker-two-reordered "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two.json" "$nfs_two_row_id" "$work/nfs-marker-two-reordered.json"
  expect_nfs_refuse marker-two-tip "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two.json" "$nfs_two_row_id" "$work/nfs-marker-two-tip-mismatch.json"
  expect_nfs_refuse marker-two-reverse "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two.json" "$nfs_two_row_id" "$work/nfs-marker-two-reverse-mismatch.json"
  expect_nfs_refuse wrong-row "$nfs_plan" "$nfs_capture" \
    "$nfs_other_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse wrong-platform "$nfs_plan" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker-wrong-platform.json"
  expect_nfs_refuse malformed-marker "$nfs_plan" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker-malformed.json"

  printf 'NFS livepatch validator matrix passed\n'

  profile_root="$work/profile-root"
  mkdir -p \
    "$profile_root/tools/livepatch" \
    "$profile_root/os/livepatches/batches/6.12.113/1/qualification/validators" \
    "$profile_root/os/livepatches/batches/6.12.113.1/qualification/validators"
  ln -s "$validator" "$profile_root/tools/livepatch/validate-generic-result.sh"
  ln -s "$nfs_validator" \
    "$profile_root/os/livepatches/batches/6.12.113/1/qualification/validators/nfs-sysfs-client-lifetime.sh"
  ln -s "$nfs_validator" \
    "$profile_root/os/livepatches/batches/6.12.113.1/qualification/validators/nfs-sysfs-client-lifetime.sh"

  printf '#!%s\n' "$BASH" >"$profile_root/tools/livepatch/verify.sh"
  cat >>"$profile_root/tools/livepatch/verify.sh" <<'EOF'
set -euo pipefail
printf '{"schemaVersion":1,"verified":true}\n'
EOF
  chmod +x "$profile_root/tools/livepatch/verify.sh"

  printf '#!%s\n' "$BASH" >"$profile_root/test-runner.sh"
  cat >>"$profile_root/test-runner.sh" <<'EOF'
set -euo pipefail

state_dir=
selector=
while (($#)); do
  case "$1" in
    --state-dir)
      state_dir=$2
      shift 2
      ;;
    --)
      selector=$2
      break
      ;;
    *) shift ;;
  esac
done
[[ -n "$state_dir" && -n "$selector" ]]
template=${selector%@*}
row_id=${selector#*@}
printf '%s\n' "$selector" >"$state_dir/selector.txt"
row=$(jq -cer --arg rowId "$row_id" \
  '[.rows[] | select(.rowId == $rowId)] | if length == 1 then .[0] else error("row selection is not unique") end' \
  "$VPSADMINOS_LIVEPATCH_PLAN")

if [[ ${FAKE_RUNNER_CASE:-success} == no-result ]]; then
  printf '[2026-11-15 13:39:38 +0100] 1 tests successful\n'
  exit 0
fi

result_dir="$state_dir/os-test-fixture"
if [[ ${FAKE_RUNNER_CASE:-success} == symlink-result ]]; then
  outside="$state_dir/../outside-result-${row_id//[^A-Za-z0-9]/_}"
  mkdir "$outside"
  ln -s "$outside" "$result_dir"
  printf '[2026-11-15 13:39:38 +0100] 1 tests successful\n'
  exit 0
fi
mkdir "$result_dir"
if [[ ${FAKE_RUNNER_CASE:-success} == duplicate-result ]]; then
  mkdir "$state_dir/os-test-duplicate"
fi

name="${template//\//-}-$row_id"
profile=$(jq -er '.profileId' <<<"$row")
set_id=$(jq -er '.setId' <<<"$row")
runner_class=$(jq -er '.runnerClass' <<<"$row")
case ${FAKE_RUNNER_CASE:-success} in
  wrong-name) name=wrong-name ;;
  wrong-profile) profile=wrong-profile ;;
  wrong-set) set_id=wrong-set ;;
  wrong-runner) runner_class=wrong-runner ;;
esac
write_config() {
  jq -n \
    --arg name "$name" \
    --arg profile "$profile" \
    --arg runner "$runner_class" \
    --arg setId "$set_id" \
    '{
      name: $name,
      labels: {
        "livepatch-profile": $profile,
        "livepatch-set": $setId
      },
      tags: [$runner]
    }' >"$1"
}
case ${FAKE_RUNNER_CASE:-success} in
  regular-config)
    write_config "$result_dir/config.json"
    ;;
  config-escape)
    config_target="$state_dir/../outside-config-${row_id//[^A-Za-z0-9]/_}.json"
    write_config "$config_target"
    ln -s "$config_target" "$result_dir/config.json"
    ;;
  dangling-config)
    ln -s "$state_dir/missing-config.json" "$result_dir/config.json"
    ;;
  missing-config)
    ;;
  nonregular-config)
    mkdir "$state_dir/nonregular-config"
    ln -s "$state_dir/nonregular-config" "$result_dir/config.json"
    ;;
  wrong-name|wrong-profile|wrong-set|wrong-runner)
    config_dir="$state_dir/prebuild-fixture"
    mkdir "$config_dir"
    write_config "$config_dir/config.json"
    ln -s "$config_dir/config.json" "$result_dir/config.json"
    ;;
  *)
    ln -s "$FAKE_STORE_CONFIG" "$result_dir/config.json"
    ;;
esac

if [[ ${FAKE_RUNNER_CASE:-success} == unsuccessful ]]; then
  printf 'unexpected_failure\n' >"$result_dir/test-result.txt"
else
  printf 'expected_success\n' >"$result_dir/test-result.txt"
fi

if [[ ${FAKE_RUNNER_CASE:-success} != missing-inner ]]; then
  : >"$result_dir/test-runner.log"
  case ${FAKE_RUNNER_CASE:-success} in
    marker-outer) ;;
    duplicate-marker)
      for _index in 1 2; do
        printf '%s ' "$FAKE_MARKER_PREFIX" >>"$result_dir/test-runner.log"
        cat "$FAKE_MARKER_FILE" >>"$result_dir/test-runner.log"
        printf '\n' >>"$result_dir/test-runner.log"
      done
      ;;
    malformed-marker)
      printf '%s {invalid-json\n' "$FAKE_MARKER_PREFIX" >"$result_dir/test-runner.log"
      ;;
    *)
      printf '%s ' "$FAKE_MARKER_PREFIX" >>"$result_dir/test-runner.log"
      cat "$FAKE_MARKER_FILE" >>"$result_dir/test-runner.log"
      printf '\n' >>"$result_dir/test-runner.log"
      ;;
  esac
  if [[ ${FAKE_RUNNER_CASE:-success} == inner-fatal ]]; then
    printf 'kernel BUG at synthetic.c:1\n' >>"$result_dir/test-runner.log"
  fi
fi

printf '[2026-11-15 13:39:38 +0100] 1 tests successful\n'
if [[ ${FAKE_RUNNER_CASE:-success} == marker-outer ]]; then
  printf '%s ' "$FAKE_MARKER_PREFIX"
  cat "$FAKE_MARKER_FILE"
  printf '\n'
fi
if [[ ${FAKE_RUNNER_CASE:-success} == outer-fatal ]]; then
  printf 'kernel BUG at synthetic.c:1\n'
fi
EOF
  chmod +x "$profile_root/test-runner.sh"

  run_profile_case() {
    local label=$1
    local plan_file=$2
    local capture_file=$3
    local selected_row=$4
    local marker_file=$5
    local marker_prefix=$6
    local runner_case=${7-success}
    local state="$work/profile-$label"

    (
      cd "$profile_root"
      FAKE_RUNNER_CASE="$runner_case" \
        FAKE_MARKER_FILE="$marker_file" \
        FAKE_MARKER_PREFIX="$marker_prefix" \
        FAKE_STORE_CONFIG="$profile_store_config" \
        "$BASH" "$profile_runner" \
          --plan "$plan_file" \
          --capture "$capture_file" \
          --row-id "$selected_row" \
          --state-dir "$state"
    )
  }

  expect_profile_refuse() {
    local label=$1
    shift
    if run_profile_case "$label" "$@" \
      >"$work/profile-$label.stdout" 2>"$work/profile-$label.stderr"; then
      echo "profile handoff refusal case unexpectedly succeeded: $label" >&2
      exit 1
    fi
    [[ ! -e "$work/profile-$label/result.json" ]]
  }

  run_profile_case generic-success \
    "$work/plan.json" "$work/capture.json" generic-lifecycle-amd \
    "$work/lifecycle.json" VPSADMINOS_LIVEPATCH_GENERIC_RESULT
  jq -e '.accepted == true and .semantic.role == "lifecycle"' \
    "$work/profile-generic-success/result.json" >/dev/null
  [[ $(cat "$work/profile-generic-success/selector.txt") == \
    'kernel/livepatch-set@generic-lifecycle-amd' ]]

  run_profile_case nfs-success \
    "$nfs_plan" "$nfs_capture" "$nfs_row_id" \
    "$work/nfs-marker.json" VPSADMINOS_LIVEPATCH_ORACLE_RESULT regular-config
  jq -e '.accepted == true and .validator.id == "nfs-client-operation-safety"' \
    "$work/profile-nfs-success/result.json" >/dev/null
  [[ $(cat "$work/profile-nfs-success/selector.txt") == \
    "kernel/livepatch-fix@$nfs_row_id" ]]
  jq -e '
    .template == "kernel/livepatch-fix"
    and .testAdapter
      == "os/livepatches/batches/6.12.113/1/qualification/helpers/nfs-sysfs-client-lifetime.nix"
  ' <<<"$nfs_row" >/dev/null

  jq --arg rowId "$nfs_row_id" '
    (.rows[] | select(.rowId == $rowId) | .validator)
      = "os/livepatches/batches/6.12.113.1/qualification/validators/nfs-sysfs-client-lifetime.sh"
  ' "$nfs_plan" >"$work/nfs-plan-flat-validator.json"
  expect_profile_refuse flat-validator-path \
    "$work/nfs-plan-flat-validator.json" "$nfs_capture" "$nfs_row_id" \
    "$work/nfs-marker.json" VPSADMINOS_LIVEPATCH_ORACLE_RESULT regular-config

  jq --arg rowId "$nfs_row_id" '
    (.rows[] | select(.rowId == $rowId) | .validator)
      = "os/livepatches/batches/6.12.113/1/qualification/validators/../validators/nfs-sysfs-client-lifetime.sh"
  ' "$nfs_plan" >"$work/nfs-plan-traversal-validator.json"
  expect_profile_refuse traversal-validator-path \
    "$work/nfs-plan-traversal-validator.json" "$nfs_capture" "$nfs_row_id" \
    "$work/nfs-marker.json" VPSADMINOS_LIVEPATCH_ORACLE_RESULT regular-config

  for profile_case in \
    no-result duplicate-result symlink-result config-escape dangling-config \
    missing-config nonregular-config wrong-name wrong-profile wrong-set \
    wrong-runner unsuccessful missing-inner \
    marker-outer duplicate-marker malformed-marker outer-fatal inner-fatal; do
    expect_profile_refuse "$profile_case" \
      "$work/plan.json" "$work/capture.json" generic-lifecycle-amd \
      "$work/lifecycle.json" VPSADMINOS_LIVEPATCH_GENERIC_RESULT "$profile_case"
  done

  if "$validator" \
    --plan "$work/plan.json" \
    --capture "$work/capture.json" \
    --row-id generic-lifecycle-amd \
    --state-dir "$work/profile-generic-success" \
    --runner-log "$work/profile-generic-success/test.log" \
    --semantic-log "$work/profile-generic-success/test.log" \
    --runner-status 0 \
    --output "$work/profile-generic-success/outer-as-semantic.json"; then
    echo 'outer controller log unexpectedly accepted as semantic log' >&2
    exit 1
  fi
  [[ ! -e "$work/profile-generic-success/outer-as-semantic.json" ]]

  jq '(.rows[] | select(.rowId == "generic-lifecycle-amd") | .validator)
    = "builtin/test-runner"' "$work/plan.json" >"$work/status-only-plan.json"
  run_profile_case status-only \
    "$work/status-only-plan.json" "$work/capture.json" generic-lifecycle-amd \
    "$work/lifecycle.json" VPSADMINOS_LIVEPATCH_GENERIC_RESULT no-result
  jq -e '
    .accepted == true
    and .validator.id == "builtin/test-runner"
    and .runnerStatus == 0
  ' "$work/profile-status-only/result.json" >/dev/null

  printf 'livepatch profile result handoff matrix passed\n'
fi

printf 'generic livepatch safety validator matrix passed\n'

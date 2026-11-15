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
    platform: {id: "amd", runnerClass: "amd-livepatch", supported: true}
  };
  [
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
        requiredProfilePlatformTuples: 3,
        activeOracles: 0,
        coverageTuples: 0,
        plannedRows: 3,
        matrixRows: 3
      }
    }
' >"$work/plan.json"

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
        if $role == "busy-transition" then {
          dimensions: $dimensions,
          initial: $one,
          forwardProgress: [{release: "6.12.113.1", before: $one, after: $two}],
          reverseProgress: [{
            removedRelease: "6.12.113.1", release: "6.12.113", before: $two, after: $three
          }],
          final: $three,
          cleanupComplete: true
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

run_validator() {
  local label=$1
  local row_id=$2
  local marker=$3
  local runner_status=$4
  local summary=$5
  local extra=${6-}
  local copies=${7-1}
  local state="$work/case-$label"

  mkdir "$state"
  printf '%s\n' "$runner_status" >"$state/runner.status"
  : >"$state/test.log"
  if [[ "$summary" == yes ]]; then
    printf '1 tests successful\n' >>"$state/test.log"
  fi
  for ((index = 0; index < copies; index++)); do
    printf 'VPSADMINOS_LIVEPATCH_GENERIC_RESULT %s\n' "$(cat "$marker")" >>"$state/test.log"
  done
  [[ -z "$extra" ]] || printf '%s\n' "$extra" >>"$state/test.log"

  "$validator" \
    --plan "$work/plan.json" \
    --capture "$work/capture.json" \
    --row-id "$row_id" \
    --state-dir "$state" \
    --runner-log "$state/test.log" \
    --runner-status "$runner_status" \
    --output "$state/result.json"
}

expect_accept() {
  local label=$1
  local row_id=$2
  local marker=$3
  run_validator "$label" "$row_id" "$marker" 0 yes
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

expect_refuse() {
  local label=$1
  shift
  if run_validator "$label" "$@" >"$work/$label.stdout" 2>"$work/$label.stderr"; then
    echo "refusal case unexpectedly succeeded: $label" >&2
    exit 1
  fi
  [[ ! -e "$work/case-$label/result.json" ]]
}

expect_accept lifecycle generic-lifecycle-amd "$work/lifecycle.json"
expect_accept busy generic-busy-amd "$work/busy.json"
expect_accept failure generic-failure-amd "$work/failure.json"

jq -c '.role = "failure-recovery"' "$work/lifecycle.json" >"$work/wrong-role.json"
jq -c '.platform.id = "intel"' "$work/lifecycle.json" >"$work/wrong-platform.json"
jq -c '.busy = null' "$work/busy.json" >"$work/missing-busy.json"
jq -c '.busy.forwardProgress[0].after.cpu = 1' "$work/busy.json" >"$work/stalled-counter.json"
jq -c '.busy.cleanupComplete = false' "$work/busy.json" >"$work/missing-cleanup.json"
jq -c '.failureRecovery.enabledRemovalRefused = false' "$work/failure.json" >"$work/missing-refusal.json"
jq -c '.kernelHealth.fatalNoiseCount = 1' "$work/lifecycle.json" >"$work/unclean-marker.json"
printf '{invalid-json\n' >"$work/malformed.json"
printf '{}\n' >"$work/empty.json"

expect_refuse wrong-role generic-lifecycle-amd "$work/wrong-role.json" 0 yes
expect_refuse wrong-platform generic-lifecycle-amd "$work/wrong-platform.json" 0 yes
expect_refuse missing-busy generic-busy-amd "$work/missing-busy.json" 0 yes
expect_refuse stalled-counter generic-busy-amd "$work/stalled-counter.json" 0 yes
expect_refuse missing-cleanup generic-busy-amd "$work/missing-cleanup.json" 0 yes
expect_refuse missing-refusal generic-failure-amd "$work/missing-refusal.json" 0 yes
expect_refuse unclean-marker generic-lifecycle-amd "$work/unclean-marker.json" 0 yes
expect_refuse malformed generic-lifecycle-amd "$work/malformed.json" 0 yes
expect_refuse duplicate generic-lifecycle-amd "$work/lifecycle.json" 0 yes '' 2
expect_refuse nonzero-runner generic-lifecycle-amd "$work/lifecycle.json" 1 yes
expect_refuse missing-summary generic-lifecycle-amd "$work/lifecycle.json" 0 no
expect_refuse fatal-noise generic-lifecycle-amd "$work/lifecycle.json" 0 yes 'kernel BUG at synthetic.c:1'

mkdir "$work/case-smoke"
printf '0\n' >"$work/case-smoke/runner.status"
printf '1 tests successful\n' >"$work/case-smoke/test.log"
if "$validator" \
  --plan "$work/plan.json" \
  --capture "$work/capture.json" \
  --row-id generic-lifecycle-amd \
  --state-dir "$work/case-smoke" \
  --runner-log "$work/case-smoke/test.log" \
  --runner-status 0 \
  --output "$work/case-smoke/result.json" \
  >"$work/smoke.stdout" 2>"$work/smoke.stderr"; then
  echo "exit-zero smoke case unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -e "$work/case-smoke/result.json" ]]

mkdir "$work/results-full"
for mapping in \
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
jq -e '.schemaVersion == 1 and .accepted == true and .plannedRows == 3 and (.receipts | length) == 3' \
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
two_member_plan.fetch('members') << deep_copy(two_member_plan.fetch('members').fetch(0)).merge(
  'release' => '6.12.113.2',
)
reordered_capture = deep_copy(captured_set)
reordered_capture.fetch('members') << deep_copy(reordered_capture.fetch('members').fetch(0)).merge(
  'release' => '6.12.113.2',
)
reordered_capture['members'].reverse!
refuse('reordered members') do
  relation.validate_nfs_capture_relation(two_member_plan, reordered_capture)
end

extra_capture = deep_copy(captured_set)
extra_capture.fetch('members') << deep_copy(extra_capture.fetch('members').fetch(0))
refuse('extra captured member') do
  relation.validate_nfs_capture_relation(planned_set, extra_capture)
end

puts 'NFS livepatch capture relation passed'
RUBY
  } >"$work/nfs-capture-relation.rb"

  "$ruby" "$work/nfs-capture-relation.rb" "$nfs_plan" "$nfs_capture"

  nfs_row=$(jq -cer '[.rows[] | select(.scope == "fix" and .platformId == "amd")]
    | if length == 1 then .[0] else error("AMD NFS row is not unique") end' "$nfs_plan")
  nfs_row_id=$(jq -er '.rowId' <<<"$nfs_row")
  nfs_other_row_id=$(jq -er '.rows[] | select(.scope == "fix" and .platformId == "intel") | .rowId' "$nfs_plan")

  jq -cn \
    --argjson row "$nfs_row" \
    --slurpfile plan "$nfs_plan" \
    --slurpfile capture "$nfs_capture" '
      {
        schemaVersion: 1,
        oracleId: "nfs-client-operation-safety",
        platformId: $row.platformId,
        runnerClass: $row.runnerClass,
        rowId: $row.rowId,
        setId: $row.setId,
        release: $capture[0].sets[0].members[0].release,
        nativeRelease: $plan[0].sets[0].kernelVersion,
        identity: $capture[0].sets[0].members[0].identity,
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
        forward: {
          enabled: 1,
          transition: 0,
          replace: 0,
          release: $capture[0].sets[0].members[0].release
        },
        reverse: {
          moduleRemoved: true,
          release: $plan[0].sets[0].kernelVersion
        },
        kernelHealth: "clean"
      }
    ' >"$work/nfs-marker.json"

  run_nfs_validator() {
    local label=$1
    local plan_file=$2
    local capture_file=$3
    local selected_row=$4
    local marker_file=$5
    local state="$work/nfs-$label"

    mkdir "$state"
    printf '0\n' >"$state/runner.status"
    {
      printf '1 tests successful\n'
      printf 'VPSADMINOS_LIVEPATCH_ORACLE_RESULT '
      cat "$marker_file"
      printf '\n'
    } >"$state/test.log"
    "$nfs_validator" \
      --plan "$plan_file" \
      --capture "$capture_file" \
      --row-id "$selected_row" \
      --state-dir "$state" \
      --runner-log "$state/test.log" \
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
  jq -e '.schemaVersion == 1 and .accepted == true and .validator.status == "accepted"' \
    "$work/nfs-valid/result.json" >/dev/null

  jq '.sets[0].members[0].kernelVersion = "6.12.114"' "$nfs_plan" >"$work/nfs-plan-target-mismatch.json"
  jq 'del(.sets[0].members[0].kernelVersion)' "$nfs_plan" >"$work/nfs-plan-target-missing.json"
  jq '.sets[0].members[0].release = "6.12.113.2"' "$nfs_capture" >"$work/nfs-capture-release-mismatch.json"
  jq '.identity.moduleSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "$work/nfs-marker.json" >"$work/nfs-marker-identity-mismatch.json"
  jq '.platformId = "intel"' "$work/nfs-marker.json" >"$work/nfs-marker-wrong-platform.json"
  printf '{invalid-json\n' >"$work/nfs-marker-malformed.json"

  expect_nfs_refuse target-mismatch "$work/nfs-plan-target-mismatch.json" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse target-missing "$work/nfs-plan-target-missing.json" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse release-mismatch "$nfs_plan" "$work/nfs-capture-release-mismatch.json" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse identity-mismatch "$nfs_plan" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker-identity-mismatch.json"
  expect_nfs_refuse wrong-row "$nfs_plan" "$nfs_capture" \
    "$nfs_other_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse wrong-platform "$nfs_plan" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker-wrong-platform.json"
  expect_nfs_refuse malformed-marker "$nfs_plan" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker-malformed.json"

  printf 'NFS livepatch validator matrix passed\n'
fi

printf 'generic livepatch safety validator matrix passed\n'

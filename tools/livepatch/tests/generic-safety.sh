#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
validator=${1:-$repository_root/tools/livepatch/validate-generic-result.sh}
verifier=${2:-$repository_root/tools/livepatch/verify.sh}
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
    members: [{release: "6.12.113.1", kernelVersion: "6.12.113"}]
  }]
}' >"$work/capture.json"

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

printf 'generic livepatch safety validator matrix passed\n'

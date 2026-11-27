#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 || ! -f "$1" || ! -d "$2" ]]; then
  echo "usage: $0 PLAN SOURCE_ROOT" >&2
  exit 2
fi

plan=$1
source_root=$2
nfs_validator=$source_root/os/livepatches/batches/6.12.113/1/qualification/validators/nfs-sysfs-client-lifetime.sh
nfsd_validator=$source_root/os/livepatches/batches/6.12.113/2/qualification/validators/nfsd-openowner-list-locking.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/livepatch-hybrid-validator.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

jq -e '
  .counts.matrixRows == 23
  and ([.rows[] | select(.scope == "fix")] | length) == 15
  and ([.rows[] | select(.scope == "fix" and .platformId == "amd")] | length) == 15
  and ([.rows[] | select(.scope == "fix" and .platformId == "intel")] | length) == 0
' "$plan" >/dev/null

jq -n --arg sha "$sha" --slurpfile plan "$plan" '
  $plan[0] as $plan
  | {
      schemaVersion: 1,
      rawBuildLogIdentity: "per-realization-only",
      sourceRevision: $plan.sourceRevision,
      flakeLockSha256: $sha,
      selectedSets: 1,
      counts: {
        plannedMembers: ($plan.sets[0].members | length),
        capturedMembers: ($plan.sets[0].members | length)
      },
      sets: [{
        id: $plan.sets[0].id,
        members: ($plan.sets[0].members | map(
          .release as $release
          | {
              release: $release,
              audit: {},
              identity: {
                closureSha256: $sha,
                flakeLockSha256: $sha,
                inputDigest: $sha,
                inspectionSha256: $sha,
                manifestSha256: $sha,
                module: ("/nix/store/11111111111111111111111111111111-livepatch/" + $release + ".ko"),
                moduleName: ("livepatch_" + ($release | gsub("\\."; "_"))),
                moduleSha256: $sha,
                producer: "/nix/store/11111111111111111111111111111111-livepatch",
                sourceRevision: $plan.sourceRevision,
                targetId: "target-6.12.113",
                vermagic: "6.12.113 SMP"
              }
            }
        ))
      }]
    }
' >"$work/capture.json"

write_marker() {
  local oracle_id=$1
  local kind=$2
  local output=$3

  jq -nc --arg oracleId "$oracle_id" --arg sha "$sha" --arg kind "$kind" \
    --slurpfile plan "$plan" --slurpfile capture "$work/capture.json" '
    $plan[0] as $plan
    | ([$plan.rows[] | select(.scope == "fix" and .oracleIds == [$oracleId])]
      | if length == 1 then .[0] else error("targeted row is not unique") end) as $row
    | ($plan.sets[0].members | map(.release)) as $releases
    | ($capture[0].sets[0].members | map(.identity)) as $identities
    | [range(($releases | length) - 1; -1; -1) as $index
        | {
            removedRelease: $releases[$index],
            release: (if $index == 0 then $plan.sets[0].kernelVersion else $releases[$index - 1] end),
            moduleRemoved: true
          }
      ] as $reverse
    | if $kind == "nfs" then {
        schemaVersion: 1,
        oracleId: $oracleId,
        platformId: $row.platformId,
        runnerClass: $row.runnerClass,
        rowId: $row.rowId,
        setId: $row.setId,
        nativeRelease: $plan.sets[0].kernelVersion,
        tipRelease: $plan.sets[0].tipRelease,
        members: ($capture[0].sets[0].members | map({release, identity})),
        workload: {mounts: 2, freshMounts: 2, operations: 1, integritySha256: $sha},
        quiescence: {mountCreation: true, finalUnmount: true, shutdownSysfsWrites: true},
        forward: ($releases | map({release: ., enabled: 1, transition: 0, replace: 0})),
        reverse: $reverse,
        kernelHealth: "clean"
      } else {
        schemaVersion: 1,
        oracleId: $oracleId,
        rowId: $row.rowId,
        setId: $row.setId,
        platformId: $row.platformId,
        runnerClass: $row.runnerClass,
        release: $plan.sets[0].tipRelease,
        nativeRelease: $plan.sets[0].kernelVersion,
        memberReleases: $releases,
        members: $identities,
        workload: {operations: 1, integritySha256: $sha, operation: $oracleId},
        forward: {
          release: $plan.sets[0].tipRelease,
          converged: true,
          boundaries: ($releases | map({release: ., enabled: 1, transition: 0, replace: 0}))
        },
        reverse: {release: $plan.sets[0].kernelVersion, modulesRemoved: true, boundaries: $reverse},
        kernelHealth: "clean"
      } end
  ' >"$output"
}

run_validator() {
  local label=$1
  local validator=$2
  local oracle_id=$3
  local marker=$4
  local plan_file=${5:-$plan}
  local state=$work/$label
  local semantic=$state/os-test-validator/test-runner.log
  local row_id

  row_id=$(jq -er --arg oracleId "$oracle_id" '
    [.rows[] | select(.scope == "fix" and .oracleIds == [$oracleId])]
    | if length == 1 then .[0].rowId else error("targeted row is not unique") end
  ' "$plan")
  mkdir -p "$(dirname -- "$semantic")"
  printf '0\n' >"$state/runner.status"
  printf '1 tests successful\n' >"$state/test.log"
  printf 'VPSADMINOS_LIVEPATCH_ORACLE_RESULT %s\n' "$(cat "$marker")" >"$semantic"

  "$BASH" "$validator" \
    --plan "$plan_file" \
    --capture "$work/capture.json" \
    --row-id "$row_id" \
    --state-dir "$state" \
    --runner-log "$state/test.log" \
    --semantic-log "$semantic" \
    --runner-status 0 \
    --output "$state/result.json"
  jq -e '.schemaVersion == 1 and .accepted == true and .validator.status == "accepted"' \
    "$state/result.json" >/dev/null
}

expect_duplicate_refusal() {
  local label=$1
  local validator=$2
  local oracle_id=$3
  local marker=$4
  local duplicate_plan=$work/$label-plan.json

  jq --arg oracleId "$oracle_id" '
    ([.rows[] | select(.scope == "fix" and .oracleIds == [$oracleId])]
      | if length == 1 then .[0] else error("targeted row is not unique") end) as $row
    | .rows += [($row | .rowId += "-duplicate")]
    | .matrix.include += [($row | .rowId += "-duplicate")]
    | .counts.plannedRows += 1
    | .counts.matrixRows += 1
  ' "$plan" >"$duplicate_plan"

  if run_validator "$label" "$validator" "$oracle_id" "$marker" "$duplicate_plan" \
    >"$work/$label.stdout" 2>"$work/$label.stderr"; then
    echo "duplicate targeted row unexpectedly accepted: $oracle_id" >&2
    exit 1
  fi
}

write_marker nfs-client-operation-safety nfs "$work/nfs-marker.json"
write_marker nfsd-openowner-operation-safety storage "$work/nfsd-marker.json"
run_validator nfs-positive "$nfs_validator" nfs-client-operation-safety "$work/nfs-marker.json"
run_validator nfsd-positive "$nfsd_validator" nfsd-openowner-operation-safety "$work/nfsd-marker.json"
expect_duplicate_refusal nfs-duplicate "$nfs_validator" nfs-client-operation-safety "$work/nfs-marker.json"
expect_duplicate_refusal nfsd-duplicate "$nfsd_validator" nfsd-openowner-operation-safety "$work/nfsd-marker.json"

printf 'hybrid targeted validator cardinality passed\n'

#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: nfs-sysfs-client-lifetime.sh --plan FILE --capture FILE --row-id ID \
       --state-dir DIR --runner-log FILE --semantic-log FILE \
       --runner-status STATUS --output FILE
EOF
  exit 2
}

fail() {
  echo "nfs-client-operation-safety: $*" >&2
  exit 1
}

plan=
capture=
row_id=
state_dir=
runner_log=
semantic_log=
runner_status=
output=

while (($#)); do
  case "$1" in
    --capture)
      (($# >= 2)) || usage
      capture=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || usage
      output=$2
      shift 2
      ;;
    --plan)
      (($# >= 2)) || usage
      plan=$2
      shift 2
      ;;
    --row-id)
      (($# >= 2)) || usage
      row_id=$2
      shift 2
      ;;
    --runner-log)
      (($# >= 2)) || usage
      runner_log=$2
      shift 2
      ;;
    --runner-status)
      (($# >= 2)) || usage
      runner_status=$2
      shift 2
      ;;
    --semantic-log)
      (($# >= 2)) || usage
      semantic_log=$2
      shift 2
      ;;
    --state-dir)
      (($# >= 2)) || usage
      state_dir=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$plan" && -n "$capture" && -n "$row_id" && -n "$state_dir" ]] || usage
[[ -n "$runner_log" && -n "$semantic_log" && -n "$runner_status" && -n "$output" ]] || usage
[[ "$runner_status" =~ ^[0-9]+$ ]] || fail "runner status is not an integer"
[[ "$runner_status" == 0 ]] || fail "runner did not succeed"

for input in "$plan" "$capture" "$runner_log" "$semantic_log"; do
  [[ -f "$input" && ! -L "$input" ]] || fail "input is not a regular non-symlink file: $input"
done
[[ -d "$state_dir" && ! -L "$state_dir" ]] || fail "state directory is invalid"
state_root=$(readlink -e -- "$state_dir")
runner_log=$(readlink -e -- "$runner_log")
semantic_log=$(readlink -e -- "$semantic_log")
[[ "$runner_log" == "$state_root/test.log" ]] || fail "runner log is outside its controller role"
semantic_dir=$(dirname -- "$semantic_log")
[[ $(dirname -- "$semantic_dir") == "$state_root" ]] || fail "semantic log is outside the state directory"
[[ "${semantic_dir##*/}" == os-test-* && -d "$semantic_dir" && ! -L "$semantic_dir" ]] || fail "semantic log result directory is invalid"
[[ "${semantic_log##*/}" == test-runner.log ]] || fail "semantic log has an unexpected name"
[[ "$semantic_log" != "$runner_log" ]] || fail "runner and semantic logs must be distinct"
[[ $(dirname -- "$output") == "$state_dir" ]] || fail "output must be inside the state directory"
[[ ! -e "$output" && ! -L "$output" ]] || fail "output already exists"
[[ -f "$state_dir/runner.status" && ! -L "$state_dir/runner.status" ]] || fail "runner.status is missing"
[[ $(cat "$state_dir/runner.status") == "$runner_status" ]] || fail "runner status file does not match"

row=$(jq -cer --arg rowId "$row_id" '
  [.rows[] | select(.rowId == $rowId)]
  | if length == 1 then .[0] else error("row selection is not unique") end
' "$plan")

jq -e --arg rowId "$row_id" '
  . as $plan
  | .sets[0] as $set
  | [.rows[] | select(
      .scope == "fix"
      and .oracleIds == ["nfs-client-operation-safety"]
    )] as $nfsRows
  | .schemaVersion == 1
  and .dormant == false
  and .selectedSets == 1
  and (.sets | length) == 1
  and ($plan.releases | length) > 0
  and ($set.members | length) > 0
  and .counts.catalogReleases == ($plan.releases | length)
  and .counts.normalizedReleases == ($plan.releases | length)
  and .counts.plannedMembers == ($set.members | length)
  and .counts.requiredProfilePlatformTuples
    == ([$plan.rows[] | select(.scope == "set")] | length)
  and .counts.activeOracles == ($set.oracleIds | length)
  and .counts.activeOracles == ($set.oracles | length)
  and .counts.coverageTuples == ($plan.coverage | length)
  and .counts.plannedRows == ($plan.rows | length)
  and .counts.matrixRows == ($plan.matrix.include | length)
  and .counts.plannedRows == .counts.matrixRows
  and ([$plan.rows[].rowId] | sort) == ([$plan.matrix.include[].rowId] | sort)
  and ([$plan.releases[].release]) == ([$set.members[].release])
  and $set.id == $set.tipRelease
  and $set.kernelVersion == "6.12.113"
  and $set.members[0].release == "6.12.113.1"
  and $set.tipRelease == $set.members[-1].release
  and ([range(0; ($set.members | length)) as $index
    | $set.members[$index].kernelVersion == $set.kernelVersion
      and $set.members[$index].releaseOrdinal == ($index + 1)
      and $set.members[$index].release
        == ("6.12.113." + (($index + 1) | tostring))
      and $set.members[$index].predecessorRelease
        == (if $index == 0 then null else $set.members[$index - 1].release end)
  ] | all)
  and ($set.oracleIds | index("nfs-client-operation-safety")) != null
  and ([$set.oracles[] | select(
    .fixId == "nfs-sysfs-client-lifetime"
    and .id == "nfs-client-operation-safety"
    and .role == "operation-safety"
  )] | length) == 1
  and ([.rows[] | select(.scope == "set") | .role] | unique | sort)
    == ["aged-transition", "busy-transition", "failure-recovery", "lifecycle"]
  and ([.rows[] | select(.scope == "set") | .oracleIds] | all(. == []))
  and ([.rows[] | select(.scope == "set") | .oracleShard] | all(. == "none"))
  and ([.rows[] | select(.scope == "set") | .validator]
    | all(. == "builtin/generic-livepatch-safety-v1"))
  and ($nfsRows | length) == 1
  and ([$nfsRows[].platformId] | sort) == ["amd"]
  and ([$nfsRows[].runnerClass] | sort) == ["amd-livepatch"]
  and ($nfsRows | all(
    .profileId == "fix/nfs-sysfs-client-lifetime/nfs-client-operation-safety"
    and .testAdapter
      == "os/livepatches/batches/6.12.113/1/qualification/helpers/nfs-sysfs-client-lifetime.nix"
    and .validator
      == "os/livepatches/batches/6.12.113/1/qualification/validators/nfs-sysfs-client-lifetime.sh"
  ))
  and ($plan.rows | all(.setId == $set.id))
  and ([.rows[] | select(.rowId == $rowId)] | length) == 1
' "$plan" >/dev/null

jq -e '
  .scope == "fix"
  and .role == "operation-safety"
  and .profileId == "fix/nfs-sysfs-client-lifetime/nfs-client-operation-safety"
  and .oracleIds == ["nfs-client-operation-safety"]
  and .oracleShard == "nfs-client-operation-safety"
  and .supported == true
  and .expectedOutcome == "success"
  and .platformId == "amd"
  and .runnerClass == "amd-livepatch"
  and .platform.id == .platformId
  and .platform.runnerClass == .runnerClass
  and .platform.supported == true
  and .testAdapter == "os/livepatches/batches/6.12.113/1/qualification/helpers/nfs-sysfs-client-lifetime.nix"
  and .validator == "os/livepatches/batches/6.12.113/1/qualification/validators/nfs-sysfs-client-lifetime.sh"
' <<<"$row" >/dev/null

jq -e --arg setId "$(jq -er '.setId' <<<"$row")" --slurpfile plan "$plan" '
  def sha: type == "string" and test("^[0-9a-f]{64}$");
  def nonempty: type == "string" and length > 0;
  . as $capture
  | $plan[0].sets[0] as $set
  | .schemaVersion == 1
  and .rawBuildLogIdentity == "per-realization-only"
  and (.sourceRevision | nonempty)
  and .sourceRevision == $plan[0].sourceRevision
  and (.flakeLockSha256 | sha)
  and .selectedSets == 1
  and .counts.plannedMembers == ($set.members | length)
  and .counts.capturedMembers == ($capture.sets[0].members | length)
  and (.sets | length) == 1
  and .sets[0].id == $setId
  and .sets[0].id == $set.id
  and (.sets[0].members | length) == ($set.members | length)
  and ([.sets[0].members[].release]) == ([$set.members[].release])
  and (.sets[0].members | all(
    (keys | sort) == ["audit", "identity", "release"]
    and .identity.sourceRevision == $capture.sourceRevision
    and .identity.flakeLockSha256 == $capture.flakeLockSha256
    and (.identity | keys | sort) == [
      "closureSha256", "flakeLockSha256", "inputDigest", "inspectionSha256",
      "manifestSha256", "module", "moduleName", "moduleSha256", "producer",
      "sourceRevision", "targetId", "vermagic"
    ]
  ))
' "$capture" >/dev/null

grep -F '1 tests successful' "$runner_log" >/dev/null || fail "runner summary is missing"
if grep -F 'tests should have succeeded' "$runner_log" >/dev/null; then
  fail "runner log contains a failure summary"
fi
noise='BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|([Rr][Cc][Uu]).*stall|livepatch.*(error|failed)|NFS:.*(fatal|error)|RPC:.*(fatal|error)'
if grep -E "$noise" "$runner_log" >/dev/null; then
  fail "runner log contains fatal kernel or NFS/RPC noise"
fi
if grep -E "$noise" "$semantic_log" >/dev/null; then
  fail "semantic log contains fatal kernel or NFS/RPC noise"
fi

marker_prefix='VPSADMINOS_LIVEPATCH_ORACLE_RESULT '
mapfile -t marker_lines < <(grep -F "$marker_prefix" "$semantic_log" || true)
[[ ${#marker_lines[@]} -eq 1 ]] || fail "expected exactly one oracle result marker"
marker_json=${marker_lines[0]#*"$marker_prefix"}

marker_tmp=$(mktemp "$state_dir/.nfs-oracle-marker.XXXXXX")
result_tmp=$(mktemp "$state_dir/.nfs-oracle-result.XXXXXX")
cleanup() {
  rm -f -- "$marker_tmp" "$result_tmp"
}
trap cleanup EXIT HUP INT TERM
chmod 0600 "$marker_tmp" "$result_tmp"
printf '%s\n' "$marker_json" > "$marker_tmp"

jq -e --argjson row "$row" --slurpfile plan "$plan" --slurpfile capture "$capture" '
  ($plan[0].sets[0].members | map(.release)) as $releases
  | ($capture[0].sets[0].members | map({release, identity})) as $members
  | [range(($releases | length) - 1; -1; -1) as $index
      | {
          removedRelease: $releases[$index],
          release: (
            if $index == 0 then $plan[0].sets[0].kernelVersion
            else $releases[$index - 1]
            end
          ),
          moduleRemoved: true
        }
    ] as $reverse
  | .schemaVersion == 1
  and (keys | sort) == [
    "forward", "kernelHealth", "members", "nativeRelease", "oracleId",
    "platformId", "quiescence", "reverse", "rowId", "runnerClass",
    "schemaVersion", "setId", "tipRelease", "workload"
  ]
  and .oracleId == "nfs-client-operation-safety"
  and .rowId == $row.rowId
  and .setId == $row.setId
  and .platformId == $row.platformId
  and .runnerClass == $row.runnerClass
  and .nativeRelease == "6.12.113"
  and .tipRelease == $plan[0].sets[0].tipRelease
  and .members == $members
  and .workload.mounts == 2
  and .workload.freshMounts == 2
  and (.workload.operations | type == "number" and floor == . and . > 0)
  and (.workload.integritySha256 | type == "string" and test("^[0-9a-f]{64}$"))
  and .quiescence == {
    mountCreation: true,
    finalUnmount: true,
    shutdownSysfsWrites: true
  }
  and .forward == ($releases | map({release: ., enabled: 1, transition: 0, replace: 0}))
  and .reverse == $reverse
  and .kernelHealth == "clean"
' "$marker_tmp" >/dev/null

jq -n \
  --arg rowId "$row_id" \
  --arg setId "$(jq -er '.setId' <<<"$row")" \
  --arg profileId "$(jq -er '.profileId' <<<"$row")" \
  --arg markerSha256 "$(sha256sum "$marker_tmp" | cut -d' ' -f1)" \
  --argjson runnerStatus "$runner_status" \
  --slurpfile marker "$marker_tmp" \
  '{
    schemaVersion: 1,
    rowId: $rowId,
    setId: $setId,
    profileId: $profileId,
    runnerStatus: $runnerStatus,
    accepted: true,
    validator: {
      id: "nfs-client-operation-safety",
      status: "accepted",
      markerSha256: $markerSha256,
      platformId: $marker[0].platformId,
      tipRelease: $marker[0].tipRelease,
      members: ($marker[0].members | map(.release)),
      operations: $marker[0].workload.operations,
      integritySha256: $marker[0].workload.integritySha256
    }
  }' > "$result_tmp"

jq -e --arg rowId "$row_id" '
  .schemaVersion == 1
  and .rowId == $rowId
  and .runnerStatus == 0
  and .accepted == true
  and .validator.id == "nfs-client-operation-safety"
  and .validator.status == "accepted"
  and (.validator.tipRelease | type == "string" and length > 0)
  and (.validator.members | type == "array" and length > 0)
  and .validator.tipRelease == .validator.members[-1]
  and (.validator.markerSha256 | test("^[0-9a-f]{64}$"))
  and (.validator.operations | type == "number" and floor == . and . > 0)
  and (.validator.integritySha256 | test("^[0-9a-f]{64}$"))
' "$result_tmp" >/dev/null

mv -T -- "$result_tmp" "$output"
trap - EXIT HUP INT TERM
rm -f -- "$marker_tmp"

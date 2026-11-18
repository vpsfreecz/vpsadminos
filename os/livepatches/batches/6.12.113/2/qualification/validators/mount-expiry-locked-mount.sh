#!/usr/bin/env bash

set -euo pipefail

expected_fix_id=mount-expiry-locked-mount
expected_oracle_id=mount-expiry-operation-safety
expected_operation_kind=mount-expiry
expected_adapter=os/livepatches/batches/6.12.113/2/qualification/helpers/mount-expiry-locked-mount.nix
expected_validator=os/livepatches/batches/6.12.113/2/qualification/validators/mount-expiry-locked-mount.sh

usage() {
  cat >&2 <<'EOF'
usage: core validator --plan FILE --capture FILE --row-id ID \
       --state-dir DIR --runner-log FILE --semantic-log FILE \
       --runner-status STATUS --output FILE
EOF
  exit 2
}

fail() {
  echo "$expected_oracle_id: $*" >&2
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
    --expected-adapter)
      (($# >= 2)) || usage
      expected_adapter=$2
      shift 2
      ;;
    --expected-fix-id)
      (($# >= 2)) || usage
      expected_fix_id=$2
      shift 2
      ;;
    --expected-operation-kind)
      (($# >= 2)) || usage
      expected_operation_kind=$2
      shift 2
      ;;
    --expected-oracle-id)
      (($# >= 2)) || usage
      expected_oracle_id=$2
      shift 2
      ;;
    --expected-validator)
      (($# >= 2)) || usage
      expected_validator=$2
      shift 2
      ;;
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
[[ "${semantic_dir##*/}" == os-test-* && -d "$semantic_dir" && ! -L "$semantic_dir" ]] \
  || fail "semantic log result directory is invalid"
[[ "${semantic_log##*/}" == test-runner.log ]] || fail "semantic log has an unexpected name"
[[ "$semantic_log" != "$runner_log" ]] || fail "runner and semantic logs must be distinct"
[[ $(dirname -- "$output") == "$state_dir" ]] || fail "output must be inside the state directory"
[[ ! -e "$output" && ! -L "$output" ]] || fail "output already exists"
[[ -f "$state_dir/runner.status" && ! -L "$state_dir/runner.status" ]] \
  || fail "runner.status is missing"
[[ $(cat "$state_dir/runner.status") == "$runner_status" ]] \
  || fail "runner status file does not match"

row=$(jq -cer --arg rowId "$row_id" '
  [.rows[] | select(.rowId == $rowId)]
  | if length == 1 then .[0] else error("row selection is not unique") end
' "$plan")
set_id=$(jq -er '.setId' <<<"$row")

jq -e \
  --arg rowId "$row_id" \
  --arg setId "$set_id" \
  --arg fixId "$expected_fix_id" \
  --arg oracleId "$expected_oracle_id" '
  .schemaVersion == 1
  and .dormant == false
  and .selectedSets == 1
  and ([.sets[] | select(.id == $setId)] | length) == 1
  and ([.sets[] | select(.id == $setId)][0].kernelVersion == "6.12.113")
  and ([.sets[] | select(.id == $setId)][0].tipRelease == "6.12.113.2")
  and ([.sets[] | select(.id == $setId)][0].members | map(.release))
    == ["6.12.113.1", "6.12.113.2"]
  and ([.sets[] | select(.id == $setId)][0].oracles
    | any(.fixId == $fixId and .id == $oracleId))
  and ([.rows[] | select(.rowId == $rowId)] | length) == 1
' "$plan" >/dev/null

jq -e \
  --arg fixId "$expected_fix_id" \
  --arg oracleId "$expected_oracle_id" \
  --arg adapter "$expected_adapter" \
  --arg validator "$expected_validator" '
  .scope == "fix"
  and .role == "operation-safety"
  and .profileId == ("fix/" + $fixId + "/" + $oracleId)
  and .oracleIds == [$oracleId]
  and .oracleShard == $oracleId
  and .supported == true
  and .expectedOutcome == "success"
  and (.platformId == "amd" or .platformId == "intel")
  and .platform.id == .platformId
  and .platform.runnerClass == .runnerClass
  and .platform.supported == true
  and .testAdapter == $adapter
  and .validator == $validator
' <<<"$row" >/dev/null

jq -e --arg setId "$set_id" --slurpfile plan "$plan" '
  def sha: type == "string" and test("^[0-9a-f]{64}$");
  def nonempty: type == "string" and length > 0;
  . as $root
  | .schemaVersion == 1
  and .rawBuildLogIdentity == "per-realization-only"
  and (.sourceRevision | nonempty)
  and (.flakeLockSha256 | sha)
  and ([.sets[] | select(.id == $setId)] | length) == 1
  and ([.sets[] | select(.id == $setId)][0].members | map(.release))
    == ["6.12.113.1", "6.12.113.2"]
  and ([.sets[] | select(.id == $setId)][0].members | all(
    (.identity | keys | sort) == [
      "closureSha256", "flakeLockSha256", "inputDigest", "inspectionSha256",
      "manifestSha256", "module", "moduleName", "moduleSha256", "producer",
      "sourceRevision", "targetId", "vermagic"
    ]
    and (.identity.moduleSha256 | sha)
    and .identity.sourceRevision == $root.sourceRevision
    and .identity.flakeLockSha256 == $root.flakeLockSha256
  ))
  and ([.sets[] | select(.id == $setId)][0].members | map(.release))
    == ([$plan[0].sets[] | select(.id == $setId)][0].members | map(.release))
' "$capture" >/dev/null

grep -F '1 tests successful' "$runner_log" >/dev/null || fail "runner summary is missing"
if grep -F 'tests should have succeeded' "$runner_log" >/dev/null; then
  fail "runner log contains a failure summary"
fi
noise='BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|([Rr][Cc][Uu]).*stall|livepatch.*(error|failed)'
if grep -E "$noise" "$runner_log" >/dev/null || grep -E "$noise" "$semantic_log" >/dev/null; then
  fail "logs contain fatal kernel or livepatch noise"
fi

marker_prefix='VPSADMINOS_LIVEPATCH_ORACLE_RESULT '
mapfile -t marker_lines < <(grep -F "$marker_prefix" "$semantic_log" || true)
[[ ${#marker_lines[@]} -eq 1 ]] || fail "expected exactly one oracle result marker"
marker_json=${marker_lines[0]#*"$marker_prefix"}
marker_tmp=$(mktemp "$state_dir/.core-oracle-marker.XXXXXX")
result_tmp=$(mktemp "$state_dir/.core-oracle-result.XXXXXX")
cleanup() {
  rm -f -- "$marker_tmp" "$result_tmp"
}
trap cleanup EXIT HUP INT TERM
chmod 0600 "$marker_tmp" "$result_tmp"
printf '%s\n' "$marker_json" > "$marker_tmp"

jq -e \
  --arg fixId "$expected_fix_id" \
  --arg oracleId "$expected_oracle_id" \
  --arg operationKind "$expected_operation_kind" \
  --argjson row "$row" \
  --arg setId "$set_id" \
  --slurpfile capture "$capture" '
  .schemaVersion == 1
  and .fixId == $fixId
  and .oracleId == $oracleId
  and .operationKind == $operationKind
  and .rowId == $row.rowId
  and .setId == $row.setId
  and .platformId == $row.platformId
  and .runnerClass == $row.runnerClass
  and .release == "6.12.113.2"
  and .nativeRelease == "6.12.113"
  and .members == ([$capture[0].sets[] | select(.id == $setId)][0].members | map(.identity))
  and (.workload.operations | type == "number" and floor == . and . > 0)
  and .forward == {release: "6.12.113.2", converged: true}
  and .reverse == {release: "6.12.113.1", targetModuleRemoved: true}
  and .cleanup == {release: "6.12.113", predecessorModuleRemoved: true}
  and .kernelHealth == "clean"
' "$marker_tmp" >/dev/null

jq -n \
  --arg rowId "$row_id" \
  --arg setId "$set_id" \
  --arg profileId "$(jq -er '.profileId' <<<"$row")" \
  --arg validatorId "$expected_oracle_id" \
  --arg markerSha256 "$(sha256sum "$marker_tmp" | cut -d' ' -f1)" \
  --argjson runnerStatus "$runner_status" \
  --slurpfile marker "$marker_tmp" '
  {
    schemaVersion: 1,
    rowId: $rowId,
    setId: $setId,
    profileId: $profileId,
    runnerStatus: $runnerStatus,
    accepted: true,
    validator: {
      id: $validatorId,
      status: "accepted",
      markerSha256: $markerSha256,
      platformId: $marker[0].platformId,
      operations: $marker[0].workload.operations
    }
  }
' > "$result_tmp"

jq -e --arg rowId "$row_id" --arg validatorId "$expected_oracle_id" '
  .schemaVersion == 1
  and .rowId == $rowId
  and .runnerStatus == 0
  and .accepted == true
  and .validator.id == $validatorId
  and .validator.status == "accepted"
  and (.validator.markerSha256 | test("^[0-9a-f]{64}$"))
  and (.validator.operations | type == "number" and floor == . and . > 0)
' "$result_tmp" >/dev/null

mv -T -- "$result_tmp" "$output"
trap - EXIT HUP INT TERM
rm -f -- "$marker_tmp"

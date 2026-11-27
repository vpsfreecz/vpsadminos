#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: nfsd-sequence-reply-preflight.sh --plan FILE --capture FILE --row-id ID \
       --state-dir DIR --runner-log FILE --semantic-log FILE \
       --runner-status STATUS --output FILE
EOF
  exit 2
}

fail() {
  echo "nfsd-sequence-operation-safety: $*" >&2
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

# Global plan/count closure and artifact admission belong to verify.sh. Bind
# this result to its selected row/set without freezing unrelated catalog rows.
jq -e '
  .scope == "fix" and .role == "operation-safety"
  and .profileId == "fix/nfsd-sequence-reply-preflight/nfsd-sequence-operation-safety"
  and .oracleIds == ["nfsd-sequence-operation-safety"]
  and .oracleShard == "nfsd-sequence-operation-safety"
  and .supported == true and .expectedOutcome == "success"
  and .platformId == "amd" and .runnerClass == "amd-livepatch"
  and .platform.id == .platformId
  and .platform.runnerClass == .runnerClass and .platform.supported == true
  and .testAdapter == "os/livepatches/batches/6.12.48/1/qualification/helpers/nfsd-sequence-reply-preflight.nix"
  and .validator == "os/livepatches/batches/6.12.48/1/qualification/validators/nfsd-sequence-reply-preflight.sh"
' <<<"$row" >/dev/null

set_id=$(jq -er '.setId' <<<"$row")
planned_set=$(jq -cer --arg setId "$set_id" '
  [.sets[] | select(.id == $setId)]
  | if length == 1 then .[0] else error("planned set is not unique") end
' "$plan")
captured_set=$(jq -cer --arg setId "$set_id" '
  [.sets[] | select(.id == $setId)]
  | if length == 1 then .[0] else error("captured set is not unique") end
' "$capture")

jq -e --argjson set "$planned_set" '
  .schemaVersion == 1 and .dormant == false
  and $set.kernelVersion == "6.12.48" and $set.tipRelease == "6.12.48.1"
  and ($set.members | length) == 1
  and $set.members[0].release == $set.tipRelease
  and $set.members[0].kernelVersion == $set.kernelVersion
  and ($set.oracleIds | index("nfsd-sequence-operation-safety")) != null
' "$plan" >/dev/null

jq -e --argjson set "$planned_set" --argjson captured "$captured_set" '
  def sha: type == "string" and test("^[0-9a-f]{64}$");
  .schemaVersion == 1 and .rawBuildLogIdentity == "per-realization-only"
  and (.sourceRevision | type == "string" and length > 0)
  and (.flakeLockSha256 | sha)
  and ($captured.members | length) == ($set.members | length)
  and ($captured.members[0] | keys | sort) == ["audit", "identity", "release"]
  and $captured.members[0].release == $set.members[0].release
  and ($captured.members[0].identity | keys | sort) == [
    "closureSha256", "flakeLockSha256", "inputDigest", "inspectionSha256",
    "manifestSha256", "module", "moduleName", "moduleSha256", "producer",
    "sourceRevision", "targetId", "vermagic"
  ]
  and $captured.members[0].identity.sourceRevision == .sourceRevision
  and $captured.members[0].identity.flakeLockSha256 == .flakeLockSha256
  and ($captured.members[0].identity | [.moduleSha256, .manifestSha256,
    .inspectionSha256, .closureSha256, .inputDigest] | all(sha))
' "$capture" >/dev/null

grep -F '1 tests successful' "$runner_log" >/dev/null || fail "runner summary is missing"
if grep -F 'tests should have succeeded' "$runner_log" >/dev/null; then
  fail "runner log contains a failure summary"
fi
noise='BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|([Rr][Cc][Uu]).*stall|livepatch.*(error|failed)|NFS:.*(fatal|error)|RPC:.*(fatal|error)'
if grep -E "$noise" "$runner_log" "$semantic_log" >/dev/null; then
  fail "logs contain fatal kernel or NFS/RPC noise"
fi
marker_prefix='VPSADMINOS_LIVEPATCH_ORACLE_RESULT '
mapfile -t marker_lines < <(grep -F "$marker_prefix" "$semantic_log" || true)
[[ ${#marker_lines[@]} -eq 1 ]] || fail "expected exactly one oracle result marker"
marker_json=${marker_lines[0]#*"$marker_prefix"}

marker_tmp=$(mktemp "$state_dir/.nfsd-oracle-marker.XXXXXX")
result_tmp=$(mktemp "$state_dir/.nfsd-oracle-result.XXXXXX")
cleanup() { rm -f -- "$marker_tmp" "$result_tmp"; }
trap cleanup EXIT HUP INT TERM
chmod 0600 "$marker_tmp" "$result_tmp"
printf '%s\n' "$marker_json" > "$marker_tmp"
jq -es 'length == 1 and (.[0] | type == "object")' "$marker_tmp" >/dev/null

jq -e --argjson row "$row" --argjson set "$planned_set" --argjson captured "$captured_set" '
  def counter: type == "number" and floor == . and . > 0;
  .schemaVersion == 1 and .oracleId == "nfsd-sequence-operation-safety"
  and .rowId == $row.rowId and .setId == $row.setId
  and .platformId == $row.platformId and .runnerClass == $row.runnerClass
  and .release == $set.tipRelease and .nativeRelease == $set.kernelVersion
  and .identity == $captured.members[0].identity
  and .workload.protocol == "4.1" and .workload.transport == "tcp"
  and .workload.mounts == 1 and .workload.freshMounts == 2
  and .workload.continuous == true
  and (.workload.integritySha256 | type == "string" and test("^[0-9a-f]{64}$"))
  and (.workload.progress | [.native, .forward, .beforeReverse, .reverse, .final] | all(counter))
  and (.workload.progress | .native < .forward and .forward < .beforeReverse
    and .beforeReverse < .reverse and .reverse <= .final)
  and .forward == {enabled: 1, transition: 0, replace: 0, release: $set.tipRelease}
  and .reverse == {moduleRemoved: true, release: $set.kernelVersion}
  and .cleanup == {workerStopped: true, mountsRemoved: true, serverStopped: true}
  and .kernelHealth == "clean"
' "$marker_tmp" >/dev/null

jq -n --argjson row "$row" \
  --arg markerSha256 "$(sha256sum "$marker_tmp" | cut -d' ' -f1)" \
  --slurpfile marker "$marker_tmp" '{
    schemaVersion: 1, rowId: $row.rowId, setId: $row.setId, profileId: $row.profileId,
    runnerStatus: 0, accepted: true,
    validator: {
      id: "nfsd-sequence-operation-safety", status: "accepted",
      markerSha256: $markerSha256, platformId: $marker[0].platformId,
      progress: $marker[0].workload.progress,
      integritySha256: $marker[0].workload.integritySha256
    }
  }' > "$result_tmp"
mv -T -- "$result_tmp" "$output"
trap - EXIT HUP INT TERM
rm -f -- "$marker_tmp"

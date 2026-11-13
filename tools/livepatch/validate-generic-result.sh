#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: validate-generic-result.sh --plan FILE --capture FILE --row-id ID \
       --state-dir DIR --runner-log FILE --runner-status STATUS --output FILE
EOF
  exit 2
}

fail() {
  echo "generic-livepatch-safety-v1: $*" >&2
  exit 1
}

plan=
capture=
row_id=
state_dir=
runner_log=
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
    --state-dir)
      (($# >= 2)) || usage
      state_dir=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$plan" && -n "$capture" && -n "$row_id" && -n "$state_dir" ]] || usage
[[ -n "$runner_log" && -n "$runner_status" && -n "$output" ]] || usage
[[ "$runner_status" =~ ^[0-9]+$ ]] || fail "runner status is not an integer"
[[ "$runner_status" == 0 ]] || fail "runner did not succeed"

for input in "$plan" "$capture" "$runner_log"; do
  [[ -f "$input" && ! -L "$input" ]] || fail "input is not a regular non-symlink file: $input"
done
[[ -d "$state_dir" && ! -L "$state_dir" ]] || fail "state directory is invalid"
[[ $(dirname -- "$output") == "$state_dir" ]] || fail "output must be inside the state directory"
[[ ! -e "$output" && ! -L "$output" ]] || fail "output already exists"
[[ -f "$state_dir/runner.status" && ! -L "$state_dir/runner.status" ]] || fail "runner.status is missing"
[[ $(cat "$state_dir/runner.status") == "$runner_status" ]] || fail "runner status file does not match"

row=$(jq -cer --arg rowId "$row_id" '
  [.rows[] | select(.rowId == $rowId)]
  | if length == 1 then .[0] else error("row selection is not unique") end
' "$plan")

jq -e '
  .scope == "set"
  and (.role == "lifecycle" or .role == "busy-transition" or .role == "failure-recovery")
  and .oracleIds == []
  and .oracleShard == "none"
  and .validator == "builtin/generic-livepatch-safety-v1"
  and .supported == true
  and .expectedOutcome == "success"
  and (.platform.id == "amd" or .platform.id == "intel")
  and .platform.supported == true
  and .platform.runnerClass == .runnerClass
  and (
    if .platform.id == "amd" then .runnerClass == "amd-livepatch"
    else .runnerClass == "intel-kvm"
    end
  )
' <<<"$row" >/dev/null

jq -e --arg setId "$(jq -er '.setId' <<<"$row")" --slurpfile plan "$plan" '
  .schemaVersion == 1
  and .selectedSets == $plan[0].selectedSets
  and .counts.capturedMembers == $plan[0].counts.plannedMembers
  and ([.sets[] | select(.id == $setId)] | length) == 1
  and ([.sets[] | select(.id == $setId)][0].members | map(.release))
    == ([ $plan[0].sets[] | select(.id == $setId) ][0].members | map(.release))
' "$capture" >/dev/null

[[ $(grep -Fxc '1 tests successful' "$runner_log") -eq 1 ]] || fail "runner success summary is missing or duplicated"
if grep -F 'tests should have succeeded' "$runner_log" >/dev/null; then
  fail "runner log contains a failure summary"
fi
noise='BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|Invalid relocation target|disagrees about version|Unknown symbol|blocked for more than|soft lockup|hard LOCKUP|([Rr][Cc][Uu]).*stall|livepatch.*(error|failed)|watchdog.*(timeout|lockup)|hung task'
if grep -E "$noise" "$runner_log" >/dev/null; then
  fail "runner log contains fatal kernel noise"
fi

marker_prefix='VPSADMINOS_LIVEPATCH_GENERIC_RESULT '
mapfile -t marker_lines < <(grep -F "$marker_prefix" "$runner_log" || true)
[[ ${#marker_lines[@]} -eq 1 ]] || fail "expected exactly one generic result marker"
[[ ${marker_lines[0]} == "$marker_prefix"* ]] || fail "generic result marker is malformed"
marker_json=${marker_lines[0]#"$marker_prefix"}

marker_tmp=$(mktemp "$state_dir/.generic-marker.XXXXXX")
result_tmp=$(mktemp "$state_dir/.generic-result.XXXXXX")
cleanup() {
  rm -f -- "$marker_tmp" "$result_tmp"
}
trap cleanup EXIT HUP INT TERM
chmod 0600 "$marker_tmp" "$result_tmp"
printf '%s\n' "$marker_json" >"$marker_tmp"

jq -e --argjson row "$row" --slurpfile plan "$plan" '
  def counter_keys: [
    "cgroupMigration", "cpu", "filesystemIntegrity", "forkExec",
    "loopbackNetwork", "scheduler"
  ];
  def counters:
    type == "object"
    and (keys | sort) == counter_keys
    and all(.[]; type == "number" and floor == . and . > 0);
  def progressed:
    .before as $before
    | .after as $after
    | ($before | counters)
    and ($after | counters)
    and all(counter_keys[]; $after[.] > $before[.]);

  $row.setId as $setId
  | ([ $plan[0].sets[] | select(.id == $setId) ] | if length == 1 then .[0] else null end) as $set
  | ($set.members | map(.release)) as $members
  | ($set.members | to_entries | reverse | map({
      removedRelease: .value.release,
      release: (if .key == 0 then $set.kernelVersion else $set.members[.key - 1].release end)
    })) as $reverse
  | (if $row.platform.id == "amd" then "AuthenticAMD" else "GenuineIntel" end) as $vendor
  | .schemaVersion == 1
  and .contract == "generic-livepatch-safety-v1"
  and (keys | sort) == [
    "busy", "contract", "failureRecovery", "forward", "kernelHealth",
    "members", "platform", "profileId", "reverse", "role", "rowId",
    "schemaVersion", "setId"
  ]
  and .rowId == $row.rowId
  and .setId == $row.setId
  and .profileId == $row.profileId
  and .role == $row.role
  and .platform == {
    id: $row.platform.id,
    architecture: "x86_64",
    cpuVendor: $vendor,
    hypervisorFlag: true,
    hypervisorVendor: "KVM",
    admitted: true
  }
  and .members == $members
  and (.forward | map(.release)) == $members
  and (.forward | all(
    (keys | sort) == ["enabled", "release", "replace", "transition"]
    and .enabled == 1 and .transition == 0 and .replace == 0
  ))
  and .reverse == $reverse
  and .kernelHealth == {clean: true, fatalNoiseCount: 0}
  and (
    if $row.role == "lifecycle" then
      .busy == null and .failureRecovery == null
    elif $row.role == "busy-transition" then
      .failureRecovery == null
      and (.busy | type == "object")
      and (.busy | keys | sort) == [
        "cleanupComplete", "dimensions", "final", "forwardProgress", "initial",
        "reverseProgress"
      ]
      and (.busy.dimensions | sort) == counter_keys
      and (.busy.initial | counters)
      and (.busy.final | counters)
      and .busy.cleanupComplete == true
      and (.busy.forwardProgress | length) == ($members | length)
      and (.busy.forwardProgress | map(.release)) == $members
      and (.busy.forwardProgress | all(
        (keys | sort) == ["after", "before", "release"] and progressed
      ))
      and (.busy.reverseProgress | length) == ($reverse | length)
      and (.busy.reverseProgress | map({removedRelease, release})) == $reverse
      and (.busy.reverseProgress | all(
        (keys | sort) == ["after", "before", "release", "removedRelease"] and progressed
      ))
    else
      .busy == null
      and .failureRecovery == {
        duplicateInsertionRefused: true,
        enabledRemovalRefused: true,
        tipUnchangedAfterDuplicate: true,
        tipUnchangedAfterRemoval: true,
        predecessorRestored: true
      }
    end
  )
' "$marker_tmp" >/dev/null

jq -n \
  --arg rowId "$row_id" \
  --arg setId "$(jq -er '.setId' <<<"$row")" \
  --arg profileId "$(jq -er '.profileId' <<<"$row")" \
  --arg markerSha256 "$(sha256sum "$marker_tmp" | cut -d' ' -f1)" \
  --argjson runnerStatus "$runner_status" \
  --slurpfile semantic "$marker_tmp" \
  '{
    schemaVersion: 1,
    rowId: $rowId,
    setId: $setId,
    profileId: $profileId,
    runnerStatus: $runnerStatus,
    accepted: true,
    validator: {
      id: "builtin/generic-livepatch-safety-v1",
      status: "accepted",
      markerSha256: $markerSha256
    },
    semantic: $semantic[0]
  }' >"$result_tmp"

jq -e --arg rowId "$row_id" '
  .schemaVersion == 1
  and .rowId == $rowId
  and .runnerStatus == 0
  and .accepted == true
  and .validator.id == "builtin/generic-livepatch-safety-v1"
  and .validator.status == "accepted"
  and (.validator.markerSha256 | test("^[0-9a-f]{64}$"))
  and .semantic.schemaVersion == 1
  and .semantic.contract == "generic-livepatch-safety-v1"
' "$result_tmp" >/dev/null

mv -T -- "$result_tmp" "$output"
trap - EXIT HUP INT TERM
rm -f -- "$marker_tmp"

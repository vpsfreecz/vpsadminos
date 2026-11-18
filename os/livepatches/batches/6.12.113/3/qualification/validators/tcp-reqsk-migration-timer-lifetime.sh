#!/usr/bin/env bash

set -euo pipefail

profile=migration
profile_seen=false

usage() {
  cat >&2 <<'EOF'
usage: tcp-reqsk-migration-timer-lifetime.sh --plan FILE --capture FILE --row-id ID \
       --state-dir DIR --runner-log FILE --semantic-log FILE \
       --runner-status STATUS --output FILE [--profile migration|cleanup|lookup]
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
    --profile)
      (($# >= 2)) || usage
      [[ "$profile_seen" == false ]] || {
        echo "duplicate profile identity" >&2
        exit 2
      }
      profile=$2
      profile_seen=true
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

case "$profile" in
  migration)
    expected_fix_id=tcp-reqsk-migration-timer-lifetime
    expected_oracle_id=tcp-reqsk-migration-timer-operation-safety
    expected_operation_label='IPv4 and IPv6 request migration timer lifecycle'
    expected_adapter=os/livepatches/batches/6.12.113/3/qualification/helpers/tcp-reqsk-migration-timer-lifetime.nix
    expected_validator=os/livepatches/batches/6.12.113/3/qualification/validators/tcp-reqsk-migration-timer-lifetime.sh
    ;;
  cleanup)
    expected_fix_id=tcp-reqsk-refcount-cleanup-preparation
    expected_oracle_id=tcp-reqsk-refcount-cleanup-operation-safety
    expected_operation_label='TCP request refcount cleanup lifecycle'
    expected_adapter=os/livepatches/batches/6.12.113/3/qualification/helpers/tcp-reqsk-refcount-cleanup-preparation.nix
    expected_validator=os/livepatches/batches/6.12.113/3/qualification/validators/tcp-reqsk-refcount-cleanup-preparation.sh
    ;;
  lookup)
    expected_fix_id=tcp-reqsk-lookup-refcount-lifetime
    expected_oracle_id=tcp-reqsk-lookup-lifetime-operation-safety
    expected_operation_label='IPv4 and IPv6 request lookup refcount lifecycle'
    expected_adapter=os/livepatches/batches/6.12.113/4/qualification/helpers/tcp-reqsk-lookup-refcount-lifetime.nix
    expected_validator=os/livepatches/batches/6.12.113/4/qualification/validators/tcp-reqsk-lookup-refcount-lifetime.sh
    ;;
  *) usage ;;
esac

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

jq -e --arg rowId "$row_id" '
  . as $plan
  | .sets[0] as $set
  | .schemaVersion == 1
  and .dormant == false
  and .selectedSets == 1
  and (.sets | length) == 1
  and ($plan.releases | length) > 0
  and ($set.members | length) > 0
  and .counts.catalogReleases == ($plan.releases | length)
  and .counts.normalizedReleases == ($plan.releases | length)
  and .counts.plannedMembers == ($set.members | length)
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
  and ($plan.rows | all(.setId == $set.id))
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
  and (
    if .platformId == "amd" then .runnerClass == "amd-livepatch"
    else .runnerClass == "intel-kvm"
    end
  )
  and .testAdapter == $adapter
  and .validator == $validator
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
noise='BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|([Rr][Cc][Uu]).*stall|livepatch.*(error|failed)|KASAN:|KFENCE:|refcount_t:|timer:.*(corrupt|invalid)'
if grep -E "$noise" "$runner_log" >/dev/null; then
  fail "runner log contains fatal kernel, refcount, timer, or livepatch noise"
fi
if grep -E "$noise" "$semantic_log" >/dev/null; then
  fail "semantic log contains fatal kernel, refcount, timer, or livepatch noise"
fi

marker_prefix='VPSADMINOS_LIVEPATCH_ORACLE_RESULT '
mapfile -t marker_lines < <(grep -F "$marker_prefix" "$semantic_log" || true)
[[ ${#marker_lines[@]} -eq 1 ]] || fail "expected exactly one oracle result marker"
marker_json=${marker_lines[0]#*"$marker_prefix"}

marker_tmp=$(mktemp "$state_dir/.$expected_fix_id-marker.XXXXXX")
result_tmp=$(mktemp "$state_dir/.$expected_fix_id-result.XXXXXX")
cleanup() {
  rm -f -- "$marker_tmp" "$result_tmp"
}
trap cleanup EXIT HUP INT TERM
chmod 0600 "$marker_tmp" "$result_tmp"
printf '%s\n' "$marker_json" > "$marker_tmp"

jq -e \
  --arg oracleId "$expected_oracle_id" \
  --arg operationLabel "$expected_operation_label" \
  --argjson row "$row" \
  --slurpfile plan "$plan" \
  --slurpfile capture "$capture" '
  def nonnegative_integer:
    type == "number" and floor == . and . >= 0;
  def positive_integer:
    type == "number" and floor == . and . > 0;
  def counter_arithmetic:
    (keys | sort) == (["baseline", "final", "delta"] | sort)
    and (.baseline | nonnegative_integer)
    and (.final | nonnegative_integer)
    and (.delta | type == "number" and floor == .)
    and .delta == (.final - .baseline);
  ($plan[0].sets[0].members | map(.release)) as $releases
  | [range(($releases | length) - 1; -1; -1) as $index
      | if $index == 0 then "6.12.113" else $releases[$index - 1] end
    ] as $reverse
  | .schemaVersion == 1
  and .oracleId == $oracleId
  and .rowId == $row.rowId
  and .setId == $row.setId
  and .platformId == $row.platformId
  and .runnerClass == $row.runnerClass
  and .release == $plan[0].sets[0].tipRelease
  and .nativeRelease == "6.12.113"
  and .identities == ($capture[0].sets[0].members | map(.identity))
  and (.workload.operations | type == "number" and floor == . and . > 0)
  and .workload.ordinaryOperation == $operationLabel
  and .workload.ipv4 == true
  and .workload.ipv6 == true
  and .workload.syncookies == 2
  and .workload.fastOpen == true
  and .workload.reuseportMigration == true
  and .workload.listenerClose == true
  and (.workload | has("timerExpiry") | not)
  and (.workload.timerCallbackMigration as $migration
    | ($migration | keys | sort) == (["schemaVersion", "operation", "families"] | sort)
    and $migration.schemaVersion == 1
    and ($migration.operation | positive_integer)
    and $migration.operation == .workload.operations
    and ($migration.families | type == "array" and length == 2)
    and ($migration.families | map(.family)) == ["ipv4", "ipv6"]
    and ($migration.families | all(
      . as $family
      | ($family | keys | sort) == ([
          "family", "counterSource", "counterScope", "namespace",
          "requestCount", "TCPMigrateReqSuccess", "TCPMigrateReqFailure",
          "acceptedCount", "roundTripCount"
        ] | sort)
      and $family.counterSource == "/proc/self/net/netstat"
      and $family.counterScope == "process-network-namespace"
      and ($family.namespace | keys | sort) == (["source", "baseline", "final"] | sort)
      and $family.namespace.source == "/proc/self/ns/net"
      and ($family.namespace.baseline
        | type == "string" and test("^net:\\[[0-9]+\\]$"))
      and $family.namespace.final == $family.namespace.baseline
      and $family.requestCount == 8
      and ($family.requestCount | positive_integer)
      and ($family."TCPMigrateReqSuccess" | counter_arithmetic)
      and $family."TCPMigrateReqSuccess".delta == $family.requestCount
      and ($family."TCPMigrateReqFailure" | counter_arithmetic)
      and $family."TCPMigrateReqFailure".delta == 0
      and $family.acceptedCount == $family.requestCount
      and $family.roundTripCount == $family.requestCount
    ))
    and $migration.families[0].namespace.baseline
      == $migration.families[1].namespace.baseline)
  and (.workload.checkpoints | length) == (1 + (2 * ($releases | length)))
  and (.workload.checkpoints | all(type == "number" and floor == . and . >= 0))
  and (.workload.checkpoints as $points
    | [range(1; $points | length) as $index
      | $points[$index] > $points[$index - 1]]
    | all)
  and .workload.operations >= .workload.checkpoints[-1]
  and .forward == {
    orderedReleases: $releases,
    replace: 0
  }
  and .reverse == {
    orderedReleases: $reverse,
    modulesRemoved: true
  }
  and .kernelHealth == "clean"
' "$marker_tmp" >/dev/null

jq -n \
  --arg rowId "$row_id" \
  --arg setId "$(jq -er '.setId' <<<"$row")" \
  --arg profileId "$(jq -er '.profileId' <<<"$row")" \
  --arg markerSha256 "$(sha256sum "$marker_tmp" | cut -d' ' -f1)" \
  --arg oracleId "$expected_oracle_id" \
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
      id: $oracleId,
      status: "accepted",
      markerSha256: $markerSha256,
      platformId: $marker[0].platformId,
      release: $marker[0].release,
      members: ($marker[0].identities | map(.moduleName)),
      operations: $marker[0].workload.operations,
      checkpoints: $marker[0].workload.checkpoints
    }
  }' > "$result_tmp"

jq -e --arg rowId "$row_id" --arg oracleId "$expected_oracle_id" '
  .schemaVersion == 1
  and .rowId == $rowId
  and .runnerStatus == 0
  and .accepted == true
  and .validator.id == $oracleId
  and .validator.status == "accepted"
  and (.validator.markerSha256 | test("^[0-9a-f]{64}$"))
  and (.validator.release | type == "string" and length > 0)
  and (.validator.members | type == "array" and length > 0)
  and (.validator.operations | type == "number" and floor == . and . > 0)
  and (.validator.checkpoints | type == "array" and length > 0)
' "$result_tmp" >/dev/null

mv -T -- "$result_tmp" "$output"
trap - EXIT HUP INT TERM
rm -f -- "$marker_tmp"

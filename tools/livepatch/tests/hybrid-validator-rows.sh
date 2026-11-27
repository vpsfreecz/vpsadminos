#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 || ! -f "$1" || ! -d "$2" ]]; then
  echo "usage: $0 PLAN SOURCE_ROOT [SEQUENCE_ORACLE RUBY]" >&2
  exit 2
fi

plan=$1
source_root=$2
sequence_oracle=${3-}
ruby=${4:-ruby}
nfs_validator=$source_root/os/livepatches/batches/6.12.113/1/qualification/validators/nfs-sysfs-client-lifetime.sh
nfsd_validator=$source_root/os/livepatches/batches/6.12.113/2/qualification/validators/nfsd-openowner-list-locking.sh
sequence_validator=$source_root/os/livepatches/batches/6.12.113/5/qualification/validators/nfsd-sequence-reply-bounds.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/livepatch-hybrid-validator.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

jq -e '
  (.sets[0].members | length) as $members
  | ($members == 4 or $members == 5)
  and .counts.matrixRows == (if $members == 4 then 23 else 24 end)
  and ([.rows[] | select(.scope == "fix")] | length) == (if $members == 4 then 15 else 16 end)
  and ([.rows[] | select(.scope == "fix" and .platformId == "amd")] | length)
    == (if $members == 4 then 15 else 16 end)
  and ([.rows[] | select(.oracleIds == ["nfsd-sequence-operation-safety"])] | length)
    == (if $members == 4 then 0 else 1 end)
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
    | (["native"] + ($releases | map("after-forward-" + .))
      + ($releases | reverse | map("after-reverse-" + .))) as $sequenceBoundaries
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
      } + (if $kind == "sequence" then {
        sequence: {operationNumber: 53, observations: (
          $sequenceBoundaries | to_entries | map({
            boundary: .value, before: (.key * 2 + 10), after: (.key * 2 + 11)
          })
        )}
      } else {} end) end
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

if [[ $(jq -r '.sets[0].members | length' "$plan") -eq 5 ]]; then
  [[ -f "$sequence_oracle" && ! -L "$sequence_oracle" ]]
  write_marker nfsd-sequence-operation-safety sequence "$work/sequence-marker.json"
  run_validator sequence-positive "$sequence_validator" nfsd-sequence-operation-safety \
    "$work/sequence-marker.json"
  expect_duplicate_refusal sequence-duplicate "$sequence_validator" \
    nfsd-sequence-operation-safety "$work/sequence-marker.json"

  expect_sequence_refusal() {
    local label=$1
    local filter=$2
    jq "$filter" "$work/sequence-marker.json" > "$work/$label-marker.json"
    if run_validator "$label" "$sequence_validator" nfsd-sequence-operation-safety \
      "$work/$label-marker.json" > "$work/$label.stdout" 2> "$work/$label.stderr"; then
      echo "SEQUENCE evidence refusal unexpectedly accepted: $label" >&2
      exit 1
    fi
    [[ ! -e "$work/$label/result.json" ]]
  }

  expect_sequence_refusal sequence-missing 'del(.sequence)'
  expect_sequence_refusal sequence-missing-boundary '.sequence.observations |= .[1:]'
  expect_sequence_refusal sequence-duplicate-boundary '.sequence.observations += [.sequence.observations[0]]'
  expect_sequence_refusal sequence-malformed '.sequence.observations[0].before = "invalid"'
  expect_sequence_refusal sequence-stagnant '.sequence.observations[0].after = .sequence.observations[0].before'
  expect_sequence_refusal sequence-decreasing '.sequence.observations[1].before = 0'
  expect_sequence_refusal sequence-wrong-member '.members[0].moduleName = "wrong-member"'
  expect_sequence_refusal sequence-incomplete-reverse '.reverse.boundaries |= .[1:]'
  expect_sequence_refusal sequence-cross-oracle '.oracleId = "nfsd-openowner-operation-safety"'

  awk '
    /NFSD_SEQUENCE_COUNTER_BEGIN/ { capture = 1; next }
    /NFSD_SEQUENCE_COUNTER_END/ { capture = 0 }
    capture { print }
  ' "$sequence_oracle" > "$work/sequence-counter.rb"
  [[ -s "$work/sequence-counter.rb" ]]
  cat >> "$work/sequence-counter.rb" <<'RUBY'
require 'shellwords'

def record(value)
  counts = Array.new(54, '0')
  counts[53] = value.to_s
  "proc4ops 54 #{counts.join(' ')}\n"
end

def refuse(label)
  yield
rescue RuntimeError
  return
else
  raise "NFSD SEQUENCE parser unexpectedly accepted #{label}"
end

raise 'SEQUENCE index changed' unless nfsd_sequence_counter(record(7)) == 7
raise 'zero SEQUENCE count rejected' unless nfsd_sequence_counter(record(0)) == 0
refuse('missing record') { nfsd_sequence_counter("proc3 0\n") }
refuse('duplicate record') { nfsd_sequence_counter(record(1) + record(2)) }
refuse('malformed declaration') { nfsd_sequence_counter(record(1).sub('54', 'invalid')) }
refuse('short declaration') { nfsd_sequence_counter('proc4ops 53 ' + Array.new(53, '0').join(' ')) }
refuse('missing field') { nfsd_sequence_counter(record(1).split[0...-1].join(' ')) }
refuse('extra field') { nfsd_sequence_counter(record(1).strip + ' 0') }
refuse('negative count') { nfsd_sequence_counter(record(-1)) }
refuse('malformed count') { nfsd_sequence_counter(record('invalid')) }

class SequenceMachine
  attr_reader :operations
  def initialize(before, after)
    @records = [before, after]
    @operations = 0
  end
  def succeeds(command)
    if command == 'cat /proc/net/rpc/nfsd'
      [0, record(@records.shift)]
    elsif command == 'nfsd-openowner-operation operate native'
      @operations += 1
      [0, '']
    else
      raise "unexpected operation: #{command}"
    end
  end
end

machine = SequenceMachine.new(10, 11)
raise 'positive operation observation changed' unless
  observe_nfsd_sequence(machine, 'native', {after: 9}) == {boundary: 'native', before: 10, after: 11}
raise 'ordinary operation did not run once' unless machine.operations == 1
refuse('stagnant operation') { observe_nfsd_sequence(SequenceMachine.new(10, 10), 'native', nil) }
refuse('decreasing operation') { observe_nfsd_sequence(SequenceMachine.new(10, 9), 'native', nil) }
refuse('between-operation reset') { observe_nfsd_sequence(SequenceMachine.new(10, 11), 'native', {after: 12}) }
puts 'NFSD SEQUENCE parser and operation observations passed'
RUBY
  "$ruby" -c "$work/sequence-counter.rb" >/dev/null
  "$ruby" "$work/sequence-counter.rb"
fi

printf 'hybrid targeted validator cardinality passed\n'

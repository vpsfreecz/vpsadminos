#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
discover=${1:-$repository_root/tools/livepatch/discover.sh}
bash=${2:-bash}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

compact_row() {
  jq -cn \
    --arg expectedOutcome success \
    --arg profileId "$2" \
    --arg rowId "$3" \
    --arg runnerClass amd-livepatch \
    --arg setId "$1" \
    --arg timeoutClass synthetic \
    '{
      expectedOutcome: $expectedOutcome,
      profileId: $profileId,
      rowId: $rowId,
      runnerClass: $runnerClass,
      setId: $setId,
      timeoutClass: $timeoutClass
    }'
}

row_a=$(compact_row 6.12.113.2 set/vendor-lifecycle row-a)
row_b=$(compact_row 6.12.114.1 set/vendor-lifecycle row-b)
jq -n --argjson rowA "$row_a" --argjson rowB "$row_b" '
  {
    schemaVersion: 1,
    dormant: false,
    selectedSets: 2,
    sourceRevision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    system: "x86_64-linux",
    releases: [
      {release: "6.12.113.1"},
      {release: "6.12.113.2"},
      {release: "6.12.114.1"}
    ],
    sets: [
      {
        id: "6.12.113.2",
        kernelVersion: "6.12.113",
        tipRelease: "6.12.113.2",
        oracleIds: ["oracle-a"],
        members: [
          {
            release: "6.12.113.1",
            kernelVersion: "6.12.113",
            releaseOrdinal: 1,
            predecessorRelease: null,
            producerAttr: "producer-a1"
          },
          {
            release: "6.12.113.2",
            kernelVersion: "6.12.113",
            releaseOrdinal: 2,
            predecessorRelease: "6.12.113.1",
            producerAttr: "producer-a2"
          }
        ]
      },
      {
        id: "6.12.114.1",
        kernelVersion: "6.12.114",
        tipRelease: "6.12.114.1",
        oracleIds: ["oracle-b"],
        members: [{
          release: "6.12.114.1",
          kernelVersion: "6.12.114",
          releaseOrdinal: 1,
          predecessorRelease: null,
          producerAttr: "producer-b1"
        }]
      }
    ],
    rows: [$rowA + {scope: "set"}, $rowB + {scope: "set"}],
    coverage: [
      {setId: "6.12.113.2", rowId: "row-a"},
      {setId: "6.12.114.1", rowId: "row-b"}
    ],
    matrix: {include: [$rowA, $rowB]},
    counts: {
      catalogReleases: 3,
      normalizedReleases: 3,
      plannedMembers: 3,
      requiredProfilePlatformTuples: 2,
      activeOracles: 2,
      coverageTuples: 2,
      plannedRows: 2,
      matrixRows: 2
    }
  }
' >"$work/full.json"

run_discover() {
  local name=$1
  shift
  "$bash" "$discover" \
    --input "$work/full.json" \
    --plan "$work/$name-plan.json" \
    --matrix "$work/$name-matrix.json" \
    "$@"
}

run_discover unfiltered
cmp "$work/full.json" "$work/unfiltered-plan.json"

printf '%s\n' docs/os/livepatches/process.md >"$work/unrelated.paths"
run_discover unrelated --changed-paths "$work/unrelated.paths"
jq -e '
  .dormant == true
  and .selectedSets == 0
  and (.sets | length) == 0
  and (.releases | length) == 0
  and (.rows | length) == 0
  and (.coverage | length) == 0
  and (.matrix.include | length) == 0
  and (.counts | all(. == 0))
' "$work/unrelated-plan.json" >/dev/null

cat >"$work/one.paths" <<'EOF'
os/livepatches/batches/6.12.113/1/default.nix
os/livepatches/batches/6.12.113/2/fixes/example.nix
EOF
run_discover one --changed-paths "$work/one.paths"
jq -e '
  .dormant == false
  and .selectedSets == 1
  and [.sets[].id] == ["6.12.113.2"]
  and [.sets[].members[].release] == ["6.12.113.1", "6.12.113.2"]
  and [.releases[].release] == ["6.12.113.1", "6.12.113.2"]
  and [.rows[].rowId] == ["row-a"]
  and [.matrix.include[].rowId] == ["row-a"]
  and .counts == {
    catalogReleases: 2,
    normalizedReleases: 2,
    plannedMembers: 2,
    requiredProfilePlatformTuples: 1,
    activeOracles: 1,
    coverageTuples: 1,
    plannedRows: 1,
    matrixRows: 1
  }
' "$work/one-plan.json" >/dev/null

cat >"$work/two.paths" <<'EOF'
os/livepatches/batches/6.12.114/1/default.nix
os/livepatches/batches/6.12.113/2/default.nix
EOF
run_discover two --changed-paths "$work/two.paths"
jq -e '.selectedSets == 2 and .counts.plannedMembers == 3' "$work/two-plan.json" >/dev/null

run_discover manual --kernel-version 6.12.114
jq -e '[.sets[].id] == ["6.12.114.1"]' "$work/manual-plan.json" >/dev/null

expect_failure() {
  local name=$1
  shift
  if run_discover "$name" "$@" >"$work/$name.out" 2>"$work/$name.err"; then
    echo "selector unexpectedly accepted $name" >&2
    exit 1
  fi
}

expect_failure duplicate --kernel-version 6.12.113 --kernel-version 6.12.113
expect_failure absent --kernel-version 6.12.999
printf '%s\n' os/livepatches/batches/6.12.999/1/default.nix >"$work/absent.paths"
expect_failure absent-path --changed-paths "$work/absent.paths"
printf '%s\n' os/livepatches/batches/6.12.113/not-an-ordinal/default.nix >"$work/malformed.paths"
expect_failure malformed --changed-paths "$work/malformed.paths"
expect_failure conflicting-selectors \
  --changed-paths "$work/one.paths" \
  --kernel-version 6.12.113

grep -Fq 'duplicate requested kernel version: 6.12.113' "$work/duplicate.err"
grep -Fq 'requested kernel is absent from the canonical plan: 6.12.999' "$work/absent.err"
grep -Fq 'requested kernel is absent from the canonical plan: 6.12.999' "$work/absent-path.err"
grep -Fq 'malformed livepatch batch path:' "$work/malformed.err"
grep -q '^usage:' "$work/conflicting-selectors.err"

echo 'livepatch discover selector checks passed'

#!/usr/bin/env bash

set -euo pipefail

if (($# != 6)); then
  echo "usage: tools/livepatch/tests/verify-capture.sh BASH VERIFY CAPTURE RUN_PROFILE CI_WORKSPACE WORKFLOW" >&2
  exit 2
fi

bash_path=$(readlink -e -- "$1")
[[ -f "$bash_path" && ! -L "$bash_path" && -x "$bash_path" ]] || {
  echo "Bash must be an executable regular non-symlink file" >&2
  exit 1
}
verify=$(readlink -e -- "$2")
[[ -f "$verify" && ! -L "$verify" ]] || {
  echo "verifier must be a regular non-symlink file" >&2
  exit 1
}
capture_script=$(readlink -e -- "$3")
run_profile=$(readlink -e -- "$4")
ci_workspace=$(readlink -e -- "$5")
workflow=$(readlink -e -- "$6")
for input in "$capture_script" "$run_profile" "$ci_workspace"; do
  [[ -f "$input" && ! -L "$input" ]] || {
    echo "interface script must be a regular non-symlink file" >&2
    exit 1
  }
done
[[ -f "$workflow" && ! -L "$workflow" ]] || {
  echo "workflow must be a regular non-symlink file" >&2
  exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/livepatch-verify-capture.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

source_revision=0123456789abcdef0123456789abcdef01234567
release=6.12.113.1
module_name=lp_test
target_id=test-target
input_digest=$(printf '%064d' 1)
vermagic='6.12.113 SMP mod_unload'
deriver=/nix/store/test-livepatch-producer.drv
dependency=/nix/store/test-livepatch-dependency

make_fixture() {
  local root=$1
  local producer="$root/producer"
  local structured="$producer/share/vpsadminos-livepatch"
  local raw="$producer/livepatch-evidence"
  local module="$producer/lib/modules/$module_name.ko"
  local bundle="$root/bundle"
  local capture_raw="$bundle/livepatch-evidence/$release/raw"

  mkdir -p -- "$structured" "$raw" "$(dirname -- "$module")" "$capture_raw" "$root/bin"
  printf 'flake lock fixture\n' >"$root/flake.lock"
  printf 'module product\n' >"$module"
  printf 'current realization log\n' >"$raw/build.log"
  printf 'captured realization log\n' >"$capture_raw/build.log"
  [[ $(sha256sum "$raw/build.log" | cut -d' ' -f1) \
    != $(sha256sum "$capture_raw/build.log" | cut -d' ' -f1) ]]

  local module_sha256 manifest_sha256 inspection_sha256 closure_sha256
  local capture_log_sha256 flake_lock_sha256
  module_sha256=$(sha256sum "$module" | cut -d' ' -f1)
  jq -n \
    --arg moduleName "$module_name" \
    --arg inputDigest "$input_digest" \
    --arg targetId "$target_id" \
    '{
      schemaVersion: 1,
      mode: "additive",
      moduleName: $moduleName,
      installPath: ("lib/modules/" + $moduleName + ".ko"),
      inputDigest: $inputDigest,
      kernelTarget: {id: $targetId},
      batch: {release: "6.12.113.1"}
    }' >"$structured/manifest.json"
  jq -n \
    --arg moduleName "$module_name" \
    --arg moduleSha256 "$module_sha256" \
    --arg vermagic "$vermagic" \
    '{
      schemaVersion: 1,
      buildInvocation: {nonReplaceRequested: true},
      module: {
        name: $moduleName,
        sha256: $moduleSha256,
        vermagic: $vermagic,
        livepatch: "Y"
      },
      functions: [],
      imports: [],
      relocations: [],
      callbacks: [],
      states: [],
      framework: {}
    }' >"$structured/inspection.json"
  jq -n '{schemaVersion: 1, matches: true, mismatches: {}}' \
    >"$structured/closure.json"
  jq -n '{functions: [], imports: [], relocations: [], callbacks: [], states: [], framework: {}}' \
    >"$structured/expected-inspection.json"
  printf 'framework\n' >"$structured/framework.patch"
  printf 'generated header\n' >"$structured/generated-header.h"
  printf 'changed object\n' >"$raw/changed-objects.txt"
  manifest_sha256=$(sha256sum "$structured/manifest.json" | cut -d' ' -f1)
  inspection_sha256=$(sha256sum "$structured/inspection.json" | cut -d' ' -f1)
  closure_sha256=$(sha256sum "$structured/closure.json" | cut -d' ' -f1)
  capture_log_sha256=$(sha256sum "$capture_raw/build.log" | cut -d' ' -f1)
  flake_lock_sha256=$(sha256sum "$root/flake.lock" | cut -d' ' -f1)
  printf '%s\n' "$dependency" "$producer" | LC_ALL=C sort -u >"$root/requisites.txt"

  jq -n \
    --arg sourceRevision "$source_revision" \
    --arg release "$release" \
    --arg producer "$producer" \
    --arg module "$module" \
    --arg moduleName "$module_name" \
    --arg moduleSha256 "$module_sha256" \
    --arg targetId "$target_id" \
    --arg inputDigest "$input_digest" \
    --arg manifestSha256 "$manifest_sha256" \
    --arg inspectionSha256 "$inspection_sha256" \
    --arg closureSha256 "$closure_sha256" \
    --arg vermagic "$vermagic" \
    --arg flakeLockSha256 "$flake_lock_sha256" \
    --arg deriver "$deriver" \
    --arg buildLogSha256 "$capture_log_sha256" \
    --rawfile requisites "$root/requisites.txt" \
    '{
      schemaVersion: 1,
      sourceRevision: $sourceRevision,
      flakeLockSha256: $flakeLockSha256,
      selectedSets: 1,
      sets: [{
        id: "test-set",
        members: [{
          release: $release,
          identity: {
            producer: $producer,
            module: $module,
            moduleName: $moduleName,
            moduleSha256: $moduleSha256,
            targetId: $targetId,
            inputDigest: $inputDigest,
            manifestSha256: $manifestSha256,
            inspectionSha256: $inspectionSha256,
            closureSha256: $closureSha256,
            vermagic: $vermagic,
            sourceRevision: $sourceRevision,
            flakeLockSha256: $flakeLockSha256
          },
          audit: {
            deriver: $deriver,
            requisites: ($requisites | split("\n") | map(select(length > 0))),
            buildLogIdentity: "per-realization-only",
            buildLogSha256: $buildLogSha256
          }
        }]
      }],
      counts: {plannedMembers: 1, capturedMembers: 1},
      rawBuildLogIdentity: "per-realization-only"
    }' >"$bundle/capture.json"

  jq -n \
    --arg sourceRevision "$source_revision" \
    --arg release "$release" \
    '{
      schemaVersion: 1,
      sourceRevision: $sourceRevision,
      selectedSets: 1,
      sets: [{id: "test-set", members: [{release: $release, producerAttr: "test-producer"}]}],
      counts: {plannedMembers: 1}
    }' >"$root/plan.json"

  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
[[ "$#" -eq 2 && "$1" == "rev-parse" && "$2" == "HEAD" ]]
printf '%s\n' "$FAKE_SOURCE_REVISION"
EOF
  } >"$root/bin/git"
  {
    printf '#!%s\n' "$bash_path"
    cat <<'EOF'
set -euo pipefail
case "$*" in
  "--option fallback false --realise $FAKE_PRODUCER")
    printf '%s\n' "$FAKE_PRODUCER"
    ;;
  "--query --deriver $FAKE_PRODUCER")
    printf '%s\n' "$FAKE_DERIVER"
    ;;
  "--query --requisites $FAKE_PRODUCER")
    printf '%s\n' "$FAKE_REQUISITE_TWO" "$FAKE_REQUISITE_ONE"
    ;;
  *)
    echo "unexpected fake nix-store invocation: $*" >&2
    exit 1
    ;;
esac
EOF
  } >"$root/bin/nix-store"
  chmod +x "$root/bin/git" "$root/bin/nix-store"
}

run_verifier() {
  local root=$1
  local capture_file=${2:-$root/bundle/capture.json}
  local selected_evidence=${3:-}
  local -a fake_requisites
  mapfile -t fake_requisites <"$root/requisites.txt"
  [[ ${#fake_requisites[@]} -eq 2 ]]
  (
    cd "$root"
    export PATH="$root/bin:$PATH"
    export FAKE_SOURCE_REVISION=$source_revision
    export FAKE_PRODUCER="$root/producer"
    export FAKE_DERIVER=$deriver
    export FAKE_REQUISITE_ONE=${fake_requisites[0]}
    export FAKE_REQUISITE_TWO=${fake_requisites[1]}
    args=(--plan "$root/plan.json" --capture "$capture_file")
    if [[ -n "$selected_evidence" ]]; then
      args+=(--evidence-dir "$selected_evidence")
    fi
    "$bash_path" "$verify" "${args[@]}"
  )
}

run_case() {
  local name=$1
  local expected=$2
  local mutation=$3
  local root="$work/$name"
  local status

  make_fixture "$root"
  "$mutation" "$root"
  set +e
  run_verifier "$root" >"$root/stdout" 2>"$root/stderr"
  status=$?
  set -e
  if [[ "$expected" == accept ]]; then
    [[ $status -eq 0 ]] || {
      echo "$name: expected acceptance, got $status" >&2
      cat "$root/stderr" >&2
      exit 1
    }
    jq -e '.schemaVersion == 1 and .verified == true' "$root/stdout" >/dev/null
  else
    [[ $status -ne 0 ]] || {
      echo "$name: expected refusal" >&2
      exit 1
    }
    [[ ! -s "$root/stdout" ]] || {
      echo "$name: refusal published a verification receipt" >&2
      exit 1
    }
  fi
}

unchanged() { :; }
remove_capture_log() { rm -- "$1/bundle/livepatch-evidence/$release/raw/build.log"; }
tamper_capture_log() { printf 'tampered\n' >>"$1/bundle/livepatch-evidence/$release/raw/build.log"; }
symlink_capture_log() {
  local path="$1/bundle/livepatch-evidence/$release/raw/build.log"
  mv -- "$path" "$1/captured-build.log"
  ln -s -- "$1/captured-build.log" "$path"
}
symlink_evidence_dir() {
  mv -- "$1/bundle/livepatch-evidence" "$1/captured-evidence"
  ln -s -- "$1/captured-evidence" "$1/bundle/livepatch-evidence"
}
invalid_capture_marker() {
  jq '.rawBuildLogIdentity = "cross-realization"' "$1/bundle/capture.json" \
    >"$1/bundle/capture.next"
  mv -- "$1/bundle/capture.next" "$1/bundle/capture.json"
}
invalid_member_marker() {
  jq '.sets[0].members[0].audit.buildLogIdentity = "cross-realization"' \
    "$1/bundle/capture.json" >"$1/bundle/capture.next"
  mv -- "$1/bundle/capture.next" "$1/bundle/capture.json"
}
tamper_module() { printf 'tampered\n' >>"$1/producer/lib/modules/$module_name.ko"; }
tamper_manifest() {
  jq '.kernelTarget.id = "wrong-target"' \
    "$1/producer/share/vpsadminos-livepatch/manifest.json" \
    >"$1/manifest.next"
  mv -- "$1/manifest.next" "$1/producer/share/vpsadminos-livepatch/manifest.json"
}
remove_current_log() { rm -- "$1/producer/livepatch-evidence/build.log"; }
symlink_current_log() {
  local path="$1/producer/livepatch-evidence/build.log"
  mv -- "$path" "$1/current-build.log"
  ln -s -- "$1/current-build.log" "$path"
}

run_case different-current-log accept unchanged
run_case missing-capture-log refuse remove_capture_log
run_case tampered-capture-log refuse tamper_capture_log
run_case symlink-capture-log refuse symlink_capture_log
run_case symlink-evidence-dir refuse symlink_evidence_dir
run_case invalid-capture-marker refuse invalid_capture_marker
run_case invalid-member-marker refuse invalid_member_marker
run_case product-mismatch refuse tamper_module
run_case structured-mismatch refuse tamper_manifest
run_case missing-current-log refuse remove_current_log
run_case symlink-current-log refuse symlink_current_log

capture_interface() {
  local root="$work/capture-interface"
  local interface="$root/interface"
  local capture_file="$interface/livepatch-capture.json"
  local selected_evidence="$interface/selected-evidence"
  local canonical_evidence="$interface/livepatch-evidence"
  local -a fake_requisites

  make_fixture "$root"
  mkdir -p -- "$root/tools/livepatch" "$interface"
  cat >"$root/tools/livepatch/discover.sh" <<EOF
#!$bash_path
set -euo pipefail
input=
plan=
matrix=
while ((\$#)); do
  case \$1 in
    --input) input=\$2; shift 2 ;;
    --plan) plan=\$2; shift 2 ;;
    --matrix) matrix=\$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
cp -- "\$input" "\$plan"
printf '{}\n' >"\$matrix"
EOF
  cat >"$root/tools/livepatch/verify.sh" <<EOF
#!$bash_path
exec "$bash_path" "$verify" "\$@"
EOF
  cat >"$root/bin/nix" <<EOF
#!$bash_path
set -euo pipefail
[[ \$# -eq 4 && \$1 == build && \$2 == --no-link && \$3 == --print-out-paths ]]
printf '%s\n' "\$FAKE_PRODUCER"
EOF
  chmod +x "$root/tools/livepatch/discover.sh" "$root/tools/livepatch/verify.sh" \
    "$root/bin/nix"
  mapfile -t fake_requisites <"$root/requisites.txt"
  (
    cd "$root"
    export PATH="$root/bin:$PATH"
    export FAKE_SOURCE_REVISION=$source_revision
    export FAKE_PRODUCER="$root/producer"
    export FAKE_DERIVER=$deriver
    export FAKE_REQUISITE_ONE=${fake_requisites[0]}
    export FAKE_REQUISITE_TWO=${fake_requisites[1]}
    "$bash_path" "$capture_script" --plan "$root/plan.json" \
      --output "$capture_file" --evidence-dir "$selected_evidence"
  )
  run_verifier "$root" "$capture_file" "$selected_evidence" >/dev/null
  if run_verifier "$root" "$capture_file" >/dev/null 2>&1; then
    echo "noncanonical evidence accepted without an override" >&2
    exit 1
  fi
  if run_verifier "$root" "$capture_file" "$interface/missing" >/dev/null 2>&1; then
    echo "missing evidence directory accepted" >&2
    exit 1
  fi
  ln -s -- "$selected_evidence" "$interface/symlink-evidence"
  if run_verifier "$root" "$capture_file" "$interface/symlink-evidence" >/dev/null 2>&1; then
    echo "symlink evidence directory accepted" >&2
    exit 1
  fi
  mv -- "$selected_evidence" "$canonical_evidence"
  run_verifier "$root" "$capture_file" >/dev/null
  mkdir -- "$interface/results"
  if "$bash_path" "$verify" --plan "$root/plan.json" \
    --results-dir "$interface/results" --output "$interface/results.json" \
    --evidence-dir "$canonical_evidence" >/dev/null 2>&1; then
    echo "campaign verification accepted an evidence directory" >&2
    exit 1
  fi
  printf 'tampered\n' >>"$canonical_evidence/$release/raw/build.log"
  if run_verifier "$root" "$capture_file" >/dev/null 2>&1; then
    echo "tampered canonical capture evidence accepted" >&2
    exit 1
  fi
}

make_run_profile_fixture() {
  local root=$1
  mkdir -p -- "$root/tools/livepatch" "$root/evidence"
  printf '{}\n' >"$root/capture.json"
  jq -n '{rows: [{
    rowId: "test-row", setId: "test-set", profileId: "test-profile",
    template: "kernel/livepatch-set", testAdapter: "kernel/livepatch-set",
    expectedOutcome: "success",
    validator: "builtin/test-runner"
  }]}' >"$root/plan.json"
  cat >"$root/tools/livepatch/verify.sh" <<EOF
#!$bash_path
printf '%s\n' "\$*" >>"\$FAKE_VERIFY_LOG"
EOF
  cat >"$root/test-runner.sh" <<EOF
#!$bash_path
printf '%s\n' "\$*" >"\$FAKE_RUNNER_LOG"
EOF
  chmod +x "$root/tools/livepatch/verify.sh" "$root/test-runner.sh"
}

invoke_run_profile() {
  local root=$1
  local state=$2
  (
    cd "$root"
    export FAKE_VERIFY_LOG="$root/verify.log"
    export FAKE_RUNNER_LOG="$root/runner.log"
    "$bash_path" "$run_profile" --plan "$root/plan.json" \
      --capture "$root/capture.json" --evidence-dir "$root/evidence" \
      --row-id test-row --state-dir "$state"
  ) >/dev/null 2>&1
}

run_profile_interface() {
  local root="$work/run-profile-interface-success"
  local state="$root/state"
  make_run_profile_fixture "$root"
  invoke_run_profile "$root" "$state"
  [[ -d "$state" && ! -L "$state" ]]
  [[ $(wc -l <"$root/verify.log") -eq 2 ]]
  [[ $(grep -F -c -- "--evidence-dir $root/evidence" "$root/verify.log") -eq 2 ]]
  [[ -s "$root/runner.log" ]]

  root="$work/run-profile-interface-regular"
  state="$root/state"
  make_run_profile_fixture "$root"
  mkdir -- "$state"
  printf 'regular sentinel\n' >"$state/sentinel"
  if invoke_run_profile "$root" "$state"; then
    echo "pre-existing regular state directory accepted" >&2
    exit 1
  fi
  [[ -d "$state" && ! -L "$state" ]]
  [[ $(cat "$state/sentinel") == 'regular sentinel' ]]
  [[ ! -e "$root/verify.log" && ! -e "$root/runner.log" ]]

  root="$work/run-profile-interface-symlink"
  state="$root/state"
  make_run_profile_fixture "$root"
  mkdir -- "$root/foreign-state"
  printf 'symlink sentinel\n' >"$root/foreign-state/sentinel"
  ln -s -- foreign-state "$state"
  if invoke_run_profile "$root" "$state"; then
    echo "pre-existing symlink state directory accepted" >&2
    exit 1
  fi
  [[ -L "$state" && $(readlink -- "$state") == foreign-state ]]
  [[ $(cat "$root/foreign-state/sentinel") == 'symlink sentinel' ]]
  [[ ! -e "$root/verify.log" && ! -e "$root/runner.log" ]]
}

expect_workspace_refusal() {
  local name=$1
  shift

  if "$bash_path" "$ci_workspace" "$@" >"$work/$name.stdout" 2>"$work/$name.stderr"; then
    echo "CI workspace refusal case accepted: $name" >&2
    exit 1
  fi
}

prepare_workspace() {
  local root=$1
  local job=$2
  local run_id=${3:-77}
  local run_attempt=${4:-2}

  "$bash_path" "$ci_workspace" prepare --root "$root" --job "$job" \
    --run-id "$run_id" --run-attempt "$run_attempt"
}

cleanup_workspace() {
  local root=$1
  local job=$2
  local directory=$3
  local run_id=${4:-77}
  local run_attempt=${5:-2}

  "$bash_path" "$ci_workspace" cleanup --root "$root" --job "$job" \
    --run-id "$run_id" --run-attempt "$run_attempt" --directory "$directory"
}

invoke_capture_fixture() {
  local root=$1
  local output=$2
  local evidence=$3
  local -a fake_requisites

  mapfile -t fake_requisites <"$root/requisites.txt"
  (
    cd "$root"
    export PATH="$root/bin:$PATH"
    export FAKE_SOURCE_REVISION=$source_revision
    export FAKE_PRODUCER="$root/producer"
    export FAKE_DERIVER=$deriver
    export FAKE_REQUISITE_ONE=${fake_requisites[0]}
    export FAKE_REQUISITE_TWO=${fake_requisites[1]}
    "$bash_path" "$capture_script" --plan "$root/plan.json" \
      --output "$output" --evidence-dir "$evidence"
  )
}

ci_workspace_interface() {
  local root="$work/ci-workspace"
  local legacy="$root/legacy"
  local capture_root="$root/capture-fixture"
  local owner output evidence first second job sentinel hash
  local -a owners=()

  mkdir -p -- "$root/scratch" "$legacy"
  for job in discovery input capture results; do
    mkdir -- "$legacy/livepatch-$job"
    printf 'legacy %s sentinel\n' "$job" >"$legacy/livepatch-$job/sentinel"
  done
  printf '{stale legacy result\n' >"$legacy/livepatch-results/result.json"
  hash=$(find "$legacy" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum)

  for job in discover capture qualify results; do
    first=$(prepare_workspace "$root/scratch" "$job")
    second=$(prepare_workspace "$root/scratch" "$job")
    [[ $first != "$second" && -d $first && ! -L $first && -O $first ]]
    [[ -d $second && ! -L $second && -O $second ]]
    [[ $(find "$first" -maxdepth 0 -printf '%m') == 700 ]]
    [[ $(find "$second" -maxdepth 0 -printf '%m') == 700 ]]
    owners+=("$job:$first" "$job:$second")
  done
  [[ $(printf '%s\n' "${owners[@]#*:}" | LC_ALL=C sort -u | wc -l) -eq 8 ]]
  expect_workspace_refusal unsupported-job prepare --root "$root/scratch" \
    --job other --run-id 77 --run-attempt 2
  expect_workspace_refusal nonnumeric-run prepare --root "$root/scratch" \
    --job capture --run-id current --run-attempt 2

  for sentinel in "${owners[@]}"; do
    cleanup_workspace "$root/scratch" "${sentinel%%:*}" "${sentinel#*:}"
  done

  make_fixture "$capture_root"
  mkdir -p -- "$capture_root/tools/livepatch"
  cat >"$capture_root/tools/livepatch/discover.sh" <<EOF
#!$bash_path
set -euo pipefail
input=
plan=
matrix=
while ((\$#)); do
  case \$1 in
    --input) input=\$2; shift 2 ;;
    --plan) plan=\$2; shift 2 ;;
    --matrix) matrix=\$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
cp -- "\$input" "\$plan"
printf '{}\n' >"\$matrix"
EOF
  cat >"$capture_root/tools/livepatch/verify.sh" <<EOF
#!$bash_path
exec "$bash_path" "$verify" "\$@"
EOF
  cat >"$capture_root/bin/nix" <<EOF
#!$bash_path
set -euo pipefail
[[ \$# -eq 4 && \$1 == build && \$2 == --no-link && \$3 == --print-out-paths ]]
printf '%s\n' "\$FAKE_PRODUCER"
EOF
  chmod +x "$capture_root/tools/livepatch/discover.sh" \
    "$capture_root/tools/livepatch/verify.sh" "$capture_root/bin/nix"

  owner=$(prepare_workspace "$root/scratch" capture)
  mkdir -- "$owner/capture"
  output="$owner/capture/capture.json"
  evidence="$owner/capture/evidence"
  invoke_capture_fixture "$capture_root" "$output" "$evidence"
  run_verifier "$capture_root" "$output" "$evidence" >/dev/null
  if invoke_capture_fixture "$capture_root" "$output" "$evidence" >/dev/null 2>&1; then
    echo 'same-invocation capture children were reused' >&2
    exit 1
  fi
  cleanup_workspace "$root/scratch" capture "$owner"
  [[ ! -e $owner && ! -L $owner ]]

  owner=$(prepare_workspace "$root/scratch" capture)
  mkdir -p -- "$owner/capture/evidence"
  printf 'capture failure sentinel\n' >"$owner/capture/evidence/sentinel"
  if invoke_capture_fixture "$capture_root" "$owner/capture/capture.json" \
    "$owner/capture/evidence" >/dev/null 2>&1; then
    echo 'pre-existing evidence directory was accepted' >&2
    exit 1
  fi
  cleanup_workspace "$root/scratch" capture "$owner"
  [[ ! -e $owner && ! -L $owner ]]

  owner=$(prepare_workspace "$root/scratch" results)
  mkdir -p -- "$owner/results/fresh"
  jq -n '{
    schemaVersion: 1,
    counts: {matrixRows: 1},
    matrix: {include: [{rowId: "fresh-row"}]},
    rows: [{rowId: "fresh-row", setId: "test-set", profileId: "test-profile", scope: "fix"}]
  }' >"$owner/plan.json"
  jq -n '{
    schemaVersion: 1,
    rowId: "fresh-row",
    setId: "test-set",
    profileId: "test-profile",
    accepted: true,
    runnerStatus: 0,
    validator: {status: "accepted"}
  }' >"$owner/results/fresh/result.json"
  "$bash_path" "$verify" --plan "$owner/plan.json" \
    --results-dir "$owner/results" --output "$owner/results/consolidated.json"
  jq -e '.accepted == true and .plannedRows == 1 and (.receipts | length) == 1' \
    "$owner/results/consolidated.json" >/dev/null
  cleanup_workspace "$root/scratch" results "$owner"

  owner=$(prepare_workspace "$root/scratch" results)
  mkdir -p -- "$owner/results/readonly"
  printf 'read-only evidence\n' >"$owner/results/readonly/evidence"
  printf 'external sentinel\n' >"$root/external-target"
  ln -s -- "$root/external-target" "$owner/results/external-link"
  chmod a-w "$owner/results/readonly"
  cleanup_workspace "$root/scratch" results "$owner"
  [[ $(cat "$root/external-target") == 'external sentinel' ]]

  owner=$(prepare_workspace "$root/scratch" results)
  mv -- "$owner" "$owner.real"
  ln -s -- "$owner.real" "$owner"
  expect_workspace_refusal top-level-symlink cleanup --root "$root/scratch" \
    --job results --run-id 77 --run-attempt 2 --directory "$owner"
  [[ -L $owner && -d $owner.real ]]
  rm -- "$owner"
  rm -rf -- "$owner.real"

  owner=$(prepare_workspace "$root/scratch" results)
  expect_workspace_refusal wrong-run cleanup --root "$root/scratch" \
    --job results --run-id 78 --run-attempt 2 --directory "$owner"
  [[ -d $owner ]]
  cleanup_workspace "$root/scratch" results "$owner"
  cleanup_workspace "$root/scratch" results "$owner"

  mkdir -- "$root/scratch/livepatch-results-77-2.short"
  expect_workspace_refusal wrong-owner-shape cleanup --root "$root/scratch" \
    --job results --run-id 77 --run-attempt 2 \
    --directory "$root/scratch/livepatch-results-77-2.short"
  [[ -d $root/scratch/livepatch-results-77-2.short ]]

  mkdir -p -- "$root/outside/livepatch-results-77-2.ABC123"
  expect_workspace_refusal outside-root cleanup --root "$root/scratch" \
    --job results --run-id 77 --run-attempt 2 \
    --directory "$root/outside/livepatch-results-77-2.ABC123"
  [[ -d $root/outside/livepatch-results-77-2.ABC123 ]]

  mkdir -- "$root/actual-root"
  ln -s -- "$root/actual-root" "$root/root-link"
  expect_workspace_refusal symlink-root prepare --root "$root/root-link" \
    --job discover --run-id 77 --run-attempt 2

  [[ $hash == "$(find "$legacy" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum)" ]]
}

workflow_interface() {
  local job

  [[ $(grep -Fc 'tools/livepatch/ci-workspace.sh prepare' "$workflow") -eq 4 ]]
  [[ $(grep -Fc 'tools/livepatch/ci-workspace.sh cleanup' "$workflow") -eq 4 ]]
  [[ $(grep -Fc -- '--directory "$LIVEPATCH_CI_WORKSPACE"' "$workflow") -eq 4 ]]
  [[ $(grep -Fc 'id: workspace' "$workflow") -eq 4 ]]
  for job in discover capture qualify results; do
    [[ $(grep -Fc "LIVEPATCH_CI_JOB: $job" "$workflow") -eq 2 ]]
  done
  if grep -Eq '\$RUNNER_TEMP/livepatch-(discovery|input|capture|results)|\$\{\{ runner[.]temp \}\}/livepatch-(discovery|input|capture|results)' \
    "$workflow"; then
    echo 'workflow retains an active fixed livepatch scratch path' >&2
    exit 1
  fi

  [[ $(grep -Fc 'uses: ./.github/actions/prepare-test-state' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'uses: ./.github/actions/cleanup-test-state' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'LIVEPATCH_PROFILE_STATE: ${{ steps.prepare-profile.outputs.state-directory }}/profile' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'path: ${{ steps.prepare-profile.outputs.state-directory }}/profile' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'state-directory: ${{ steps.prepare-profile.outputs.state-directory }}' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'steps.cleanup-profile.outcome == '\''success'\''' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'steps.upload-result.outcome == '\''success'\''' "$workflow") -eq 1 ]]
  [[ $(grep -Ec '^[[:space:]]*path: \$\{\{ steps[.]workspace[.]outputs[.]directory \}\}$' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Ec '^[[:space:]]*path: \$\{\{ steps[.]workspace[.]outputs[.]directory \}\}/capture$' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Ec '^[[:space:]]*path: \$\{\{ steps[.]workspace[.]outputs[.]directory \}\}/results$' \
    "$workflow") -eq 2 ]]
}

capture_interface
run_profile_interface
ci_workspace_interface
workflow_interface

echo "livepatch capture verifier matrix passed"

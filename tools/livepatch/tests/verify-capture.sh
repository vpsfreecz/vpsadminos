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
qualification_workflow=
qualification_workflow_candidate="$(dirname -- "$workflow")/livepatch-qualification.yml"
if [[ -f "$qualification_workflow_candidate" && ! -L "$qualification_workflow_candidate" ]]; then
  qualification_workflow=$(readlink -e -- "$qualification_workflow_candidate")
fi
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
    [[ "${FAKE_PRODUCER_AVAILABLE:-true}" == true ]] || {
      echo "captured producer is unavailable" >&2
      exit 1
    }
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
    export FAKE_PRODUCER_AVAILABLE=true
    if [[ -e "$root/missing-producer" ]]; then
      FAKE_PRODUCER_AVAILABLE=false
    fi
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
remove_producer_from_store() { : > "$1/missing-producer"; }

run_case different-current-log accept unchanged
run_case missing-producer refuse remove_producer_from_store
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

extract_workflow_run_block() {
  local step_name=$1
  local output=$2
  local body=false
  local line
  local selected=false

  : >"$output"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "      - name: $step_name" ]]; then
      selected=true
      continue
    fi
    if $selected && [[ "$line" == '        run: |' ]]; then
      body=true
      continue
    fi
    if $body && [[ "$line" == '      - '* ]]; then
      break
    fi
    if $body; then
      printf '%s\n' "${line#          }" >>"$output"
    fi
  done <"$workflow"
  [[ -s "$output" ]]
}

make_resume_import_fixture() {
  local root=$1
  local run_id=45086108111
  local run_attempt=1
  local accepted_row=6.12.113.4--set-vendor-aged-transition--amd
  local accepted_artifact="livepatch-result-$accepted_row-$run_id-$run_attempt"
  local failed_artifact="livepatch-result-pending-one-$run_id-$run_attempt"
  local resume="$root/workspace/resume"

  mkdir -p -- "$root/bin" "$root/tools/livepatch" "$resume/plan" \
    "$resume/capture/evidence" "$resume/results/$accepted_artifact" \
    "$resume/results/$failed_artifact"
  jq -n --arg sourceRevision "$source_revision" --arg accepted "$accepted_row" '{
    schemaVersion: 1,
    sourceRevision: $sourceRevision,
    selectedSets: 1,
    counts: {matrixRows: 3},
    sets: [{
      id: "test-set", kernelVersion: "6.12.113", tipRelease: "6.12.113.4",
      members: [{release: "6.12.113.4"}]
    }],
    matrix: {include: [
      {rowId: $accepted},
      {rowId: "pending-one"},
      {rowId: "pending-two"}
    ]},
    rows: [
      {rowId: $accepted, setId: "test-set", profileId: "aged", scope: "fix"},
      {rowId: "pending-one", setId: "test-set", profileId: "one", scope: "fix"},
      {rowId: "pending-two", setId: "test-set", profileId: "two", scope: "fix"}
    ]
  }' >"$resume/plan/plan.json"
  jq '.matrix' "$resume/plan/plan.json" >"$resume/plan/matrix.json"
  jq '{schemaVersion, sourceRevision, selectedSets, sets, counts}' \
    "$resume/plan/plan.json" >"$resume/plan/affected-plan.json"
  jq -n --arg sourceRevision "$source_revision" '{
    schemaVersion: 1,
    sourceRevision: $sourceRevision
  }' >"$resume/capture/capture.json"
  printf 'evidence\n' >"$resume/capture/evidence/member"
  jq -n --arg rowId "$accepted_row" '{
    schemaVersion: 1,
    rowId: $rowId,
    setId: "test-set",
    profileId: "aged",
    accepted: true,
    runnerStatus: 0,
    validator: {status: "accepted"}
  }' >"$resume/results/$accepted_artifact/result.json"
  jq -n '{
    schemaVersion: 1,
    rowId: "pending-one",
    setId: "test-set",
    profileId: "one",
    accepted: false,
    runnerStatus: 1,
    validator: {status: "failed"}
  }' >"$resume/results/$failed_artifact/result.json"
  jq -n \
    --arg sourceRevision "$source_revision" \
    --arg controllerRevision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --arg planSha256 "$(sha256sum "$resume/plan/plan.json" | cut -d' ' -f1)" \
    --arg captureSha256 "$(sha256sum "$resume/capture/capture.json" | cut -d' ' -f1)" \
    --arg planName "livepatch-plan-$run_id-$run_attempt" \
    --arg captureName "livepatch-capture-$run_id-$run_attempt" \
    --arg acceptedArtifact "$accepted_artifact" \
    --arg failedArtifact "$failed_artifact" '{
      schemaVersion: 1,
      source: {
        repository: "vpsfreecz/vpsadminos",
        runId: 45086108111,
        runAttempt: 1,
        headSha: $sourceRevision,
        status: "completed",
        workflowId: 7,
        workflowPath: ".github/workflows/livepatch-qualification.yml"
      },
      controller: {
        headSha: $controllerRevision,
        runId: 9,
        runAttempt: 1
      },
      requested: {
        planSha256: $planSha256,
        captureSha256: $captureSha256
      },
      artifacts: [
        {name: $planName},
        {name: $captureName},
        {name: $acceptedArtifact},
        {name: $failedArtifact}
      ] | map(. + {
        id: 1,
        digest: ("sha256:" + ("1" * 64)),
        sizeInBytes: 1,
        createdAt: "2026-11-23T00:00:00Z",
        expired: false,
        expiresAt: "2026-12-23T00:00:00Z"
      })
    }' >"$root/workspace/resume-provenance-api.json"
  sha256sum "$resume/plan/plan.json" | cut -d' ' -f1 >"$root/plan.sha256"
  sha256sum "$resume/capture/capture.json" | cut -d' ' -f1 >"$root/capture.sha256"
  sha256sum "$resume/results/$accepted_artifact/result.json" \
    | cut -d' ' -f1 >"$root/result.sha256"

  cat >"$root/bin/git" <<EOF
#!$bash_path
set -euo pipefail
[[ "\$#" -eq 2 && "\$1" == rev-parse && "\$2" == HEAD ]]
printf '%s\n' '$source_revision'
EOF
  cat >"$root/tools/livepatch/verify.sh" <<EOF
#!$bash_path
set -euo pipefail
plan=
row=
result=
while ((\$#)); do
  case \$1 in
    --plan) plan=\$2; shift 2 ;;
    --capture|--evidence-dir) shift 2 ;;
    --row-id) row=\$2; shift 2 ;;
    --result) result=\$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ -f \$plan ]]
if [[ -n \$row ]]; then
  [[ -f \$result ]]
  jq -e --arg rowId "\$row" '
    (.rowId == \$rowId)
    and (\$plan[0].rows | map(.rowId) | index(\$rowId) != null)
  ' --slurpfile plan "\$plan" "\$result" >/dev/null
else
  printf '{"schemaVersion":1,"verified":true}\n'
fi
EOF
  chmod +x "$root/bin/git" "$root/tools/livepatch/verify.sh"
}

mutate_json() {
  local path=$1
  local filter=$2
  jq "$filter" "$path" >"$path.next"
  mv -- "$path.next" "$path"
}

run_resume_import() {
  local root=$1
  local output="$root/github-output"
  (
    cd "$root"
    export PATH="$root/bin:$PATH"
    export CONTROLLER_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    export EVENT_NAME=workflow_dispatch
    EXPECTED_CAPTURE_ARCHIVE_SHA256=$(printf '%064d' 0 | tr 0 1)
    export EXPECTED_CAPTURE_ARCHIVE_SHA256
    export EXPECTED_IMPORTED_ROW_ID=6.12.113.4--set-vendor-aged-transition--amd
    EXPECTED_IMPORTED_RESULT_ARCHIVE_SHA256=$(printf '%064d' 0 | tr 0 1)
    export EXPECTED_IMPORTED_RESULT_ARCHIVE_SHA256
    EXPECTED_IMPORTED_RESULT_SHA256=$(cat "$root/result.sha256")
    export EXPECTED_IMPORTED_RESULT_SHA256
    export EXPECTED_IMPORTED_ROWS=1
    export EXPECTED_PLANNED_ROWS=3
    EXPECTED_PLAN_ARCHIVE_SHA256=$(printf '%064d' 0 | tr 0 1)
    export EXPECTED_PLAN_ARCHIVE_SHA256
    export EXPECTED_REPOSITORY=vpsfreecz/vpsadminos
    export GITHUB_OUTPUT="$output"
    export LIVEPATCH_CI_WORKSPACE="$root/workspace"
    export MANUAL_KERNELS=
    RESUME_CAPTURE_SHA256=$(cat "$root/capture.sha256")
    export RESUME_CAPTURE_SHA256
    export RESUME_MODE=true
    RESUME_PLAN_SHA256=$(cat "$root/plan.sha256")
    export RESUME_PLAN_SHA256
    export RESUME_SOURCE_REVISION=$source_revision
    export RESUME_SOURCE_RUN_ATTEMPT=1
    export RESUME_SOURCE_RUN_ID=45086108111
    "$bash_path" "$work/discover-plan-run.sh"
  )
}

run_resume_case() {
  local name=$1
  local expected=$2
  local mutation=$3
  local root="$work/resume-$name"
  local status

  make_resume_import_fixture "$root"
  "$mutation" "$root"
  set +e
  run_resume_import "$root" >"$root/stdout" 2>"$root/stderr"
  status=$?
  set -e
  if [[ "$expected" == accept ]]; then
    [[ $status -eq 0 ]] || {
      echo "$name: resume import expected acceptance, got $status" >&2
      cat "$root/stderr" >&2
      exit 1
    }
    [[ $(jq -er '.include | length' "$root/workspace/matrix.json") == 2 ]]
    [[ $(find "$root/workspace/imported-results" -type f -name result.json | wc -l) == 1 ]]
    grep -Fx 'imported-rows=1' "$root/github-output" >/dev/null
  else
    [[ $status -ne 0 ]] || {
      echo "$name: resume import expected refusal" >&2
      exit 1
    }
  fi
}

resume_unchanged() { :; }
resume_wrong_repository() {
  mutate_json "$1/workspace/resume-provenance-api.json" '.source.repository = "other/repo"'
}
resume_wrong_head() {
  mutate_json "$1/workspace/resume-provenance-api.json" \
    '.source.headSha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
}
resume_wrong_run() {
  mutate_json "$1/workspace/resume-provenance-api.json" '.source.runId = 2'
}
resume_wrong_attempt() {
  mutate_json "$1/workspace/resume-provenance-api.json" '.source.runAttempt = 2'
}
resume_wrong_workflow() {
  mutate_json "$1/workspace/resume-provenance-api.json" \
    '.source.workflowPath = ".github/workflows/other.yml"'
}
resume_wrong_plan_hash() { printf '\n' >>"$1/workspace/resume/plan/plan.json"; }
resume_wrong_capture_hash() { printf '\n' >>"$1/workspace/resume/capture/capture.json"; }
resume_missing_artifact() {
  mutate_json "$1/workspace/resume-provenance-api.json" \
    '[.artifacts[] | select(.name | startswith("livepatch-capture-") | not)] as $a | .artifacts = $a'
}
resume_duplicate_artifact() {
  mutate_json "$1/workspace/resume-provenance-api.json" \
    '.artifacts += [.artifacts[] | select(.name | startswith("livepatch-plan-"))]'
}
resume_expired_artifact() {
  mutate_json "$1/workspace/resume-provenance-api.json" '.artifacts[0].expired = true'
}
resume_wrong_service_digest() {
  mutate_json "$1/workspace/resume-provenance-api.json" \
    '.artifacts[0].digest = ("sha256:" + ("2" * 64))'
}
resume_duplicate_row() {
  local root=$1
  local results="$root/workspace/resume/results"
  local duplicate=livepatch-result-duplicate-45086108111-1
  mkdir "$results/$duplicate"
  cp -- "$results/livepatch-result-6.12.113.4--set-vendor-aged-transition--amd-45086108111-1/result.json" \
    "$results/$duplicate/result.json"
  mutate_json "$root/workspace/resume-provenance-api.json" \
    ".artifacts += [{id: 2, name: \"$duplicate\", digest: (\"sha256:\" + (\"2\" * 64)), sizeInBytes: 1, createdAt: \"2026-11-23T00:00:00Z\", expired: false, expiresAt: \"2026-12-23T00:00:00Z\"}]"
}
resume_unknown_row() {
  local result="$1/workspace/resume/results/livepatch-result-pending-one-45086108111-1/result.json"
  mutate_json "$result" '.rowId = "unknown-row"'
}
resume_symlink_result() {
  local root=$1
  local result="$root/workspace/resume/results/livepatch-result-pending-one-45086108111-1/result.json"
  mv -- "$result" "$root/external-result.json"
  ln -s -- "$root/external-result.json" "$result"
}
resume_malformed_success() {
  local result="$1/workspace/resume/results/livepatch-result-pending-one-45086108111-1/result.json"
  mutate_json "$result" '.accepted = true'
}

resume_import_interface() {
  extract_workflow_run_block 'Discover one canonical plan and its affected view' \
    "$work/discover-plan-run.sh"
  chmod +x "$work/discover-plan-run.sh"
  run_resume_case success accept resume_unchanged
  run_resume_case cross-repository refuse resume_wrong_repository
  run_resume_case cross-head refuse resume_wrong_head
  run_resume_case wrong-run refuse resume_wrong_run
  run_resume_case wrong-attempt refuse resume_wrong_attempt
  run_resume_case wrong-workflow refuse resume_wrong_workflow
  run_resume_case wrong-plan-hash refuse resume_wrong_plan_hash
  run_resume_case wrong-capture-hash refuse resume_wrong_capture_hash
  run_resume_case absent-artifact refuse resume_missing_artifact
  run_resume_case duplicate-artifact refuse resume_duplicate_artifact
  run_resume_case expired-artifact refuse resume_expired_artifact
  run_resume_case wrong-service-digest refuse resume_wrong_service_digest
  run_resume_case duplicate-row refuse resume_duplicate_row
  run_resume_case unknown-row refuse resume_unknown_row
  run_resume_case symlink-result refuse resume_symlink_result
  run_resume_case malformed-success refuse resume_malformed_success
}

resume_jobs_are_eligible() {
  local jobs=$1

  ! jq -e 'any(.[];
    (.name | startswith("Ordinary CI on ")) and .conclusion == "success"
  )' "$jobs" >/dev/null
}

resume_jobs_pagination_interface() {
  local all_jobs="$work/resume-all-jobs.json"
  local batch="$work/resume-job-batch.json"
  local collected="$work/resume-collected-jobs.json"
  local next="$work/resume-collected-jobs.next"
  local ordinary="$work/resume-ordinary-success-jobs.json"
  local artifact_line artifact_key_line jobs_key_line jobs_page_line jobs_route_line
  local count offset page pages=0
  local page_size=25

  [[ $(grep -Fc 'async function collect(route, key, perPage = 100)' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'for (let page = 1; page <= 100; page += 1)' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'per_page: perPage' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'if (batch.length < perPage) return rows' "$workflow") -eq 1 ]]

  jobs_route_line=$(grep -nF \
    "'GET /repos/{owner}/{repo}/actions/runs/{run_id}/attempts/{attempt_number}/jobs'," \
    "$workflow" | cut -d: -f1)
  jobs_key_line=$(grep -nF "              'jobs'," "$workflow" | cut -d: -f1)
  jobs_page_line=$(grep -nF '              25,' "$workflow" | cut -d: -f1)
  artifact_line=$(grep -nF 'const artifacts = await collect(' "$workflow" | cut -d: -f1)
  artifact_key_line=$(grep -nF "              'artifacts'," "$workflow" | cut -d: -f1)
  [[ -n "$jobs_route_line" && -n "$jobs_key_line" && -n "$jobs_page_line" ]]
  ((jobs_route_line < jobs_key_line && jobs_key_line < jobs_page_line))
  [[ -n "$artifact_line" && -n "$artifact_key_line" ]]
  ((artifact_line < artifact_key_line))
  ((artifact_key_line < artifact_line + 5))
  [[ $(sed -n "${artifact_line},$((artifact_line + 4))p" "$workflow" |
    grep -Fc '              25,') -eq 0 ]]

  jq -n '[range(1; 89) | {
    id: ., name: ("Qualification row " + tostring), conclusion: "failure"
  }]' > "$all_jobs"
  printf '[]\n' > "$collected"
  for page in $(seq 1 100); do
    offset=$(((page - 1) * page_size))
    jq --argjson offset "$offset" --argjson pageSize "$page_size" \
      '.[$offset:($offset + $pageSize)]' "$all_jobs" > "$batch"
    jq -s '.[0] + .[1]' "$collected" "$batch" > "$next"
    mv -- "$next" "$collected"
    pages=$page
    count=$(jq -er 'length' "$batch")
    ((count < page_size)) && break
  done
  [[ $pages -eq 4 ]]
  jq -e '
    length == 88
    and ([.[].id] | unique | length) == 88
    and [.[].id] == [range(1; 89)]
  ' "$collected" >/dev/null
  jq -e --slurp '.[0] == .[1]' "$all_jobs" "$collected" >/dev/null
  resume_jobs_are_eligible "$collected"

  jq '
    .[-1].name = "Ordinary CI on 6.12.113.4"
    | .[-1].conclusion = "success"
  ' "$collected" > "$ordinary"
  if resume_jobs_are_eligible "$ordinary"; then
    echo 'resume job pagination accepted a late-page ordinary success' >&2
    exit 1
  fi
}

workflow_interface() {
  local capture_hash_line capture_input_line capture_line capture_plan_line
  local capture_resume_condition_line capture_resume_line capture_resume_name_line
  local capture_resume_path_line checkout_line coverage_line evidence_input_line
  local field input job prepare_line publish_line resume_line upload_line

  if [[ -n "$qualification_workflow" ]]; then
    [[ $(grep -Fc -- "- '!qualification-resume/**'" "$qualification_workflow") -eq 1 ]]
    [[ $(grep -Fc 'actions: read' "$qualification_workflow") -eq 1 ]]
    for input in resume_source_run_id resume_source_run_attempt \
      resume_source_revision resume_plan_sha256 resume_capture_sha256; do
      [[ $(grep -Fc "      $input:" "$qualification_workflow") -eq 1 ]]
    done
    for input in resume-source-run-id resume-source-run-attempt \
      resume-source-revision resume-plan-sha256 resume-capture-sha256; do
      [[ $(grep -Fc "      $input: \${{ inputs.${input//-/_} }}" \
        "$qualification_workflow") -eq 1 ]]
    done
    [[ $(grep -Fc 'actions/download-artifact@v7' "$qualification_workflow") -eq 0 ]]
    [[ $(grep -Fc 'actions/download-artifact@v8' "$qualification_workflow") -eq 0 ]]
  fi
  [[ $(grep -Fc 'actions: read' "$workflow") -eq 1 ]]
  for input in resume-source-run-id resume-source-run-attempt \
    resume-source-revision resume-plan-sha256 resume-capture-sha256; do
    [[ $(grep -Fc "      $input:" "$workflow") -eq 1 ]]
  done
  [[ $(grep -Fc 'uses: actions/github-script@v9' "$workflow") -eq 1 ]]
  resume_line=$(grep -nF 'name: Validate qualification resume provenance' \
    "$workflow" | cut -d: -f1)
  checkout_line=$(grep -nF "ref: \${{ inputs['resume-source-revision'] || github.sha }}" \
    "$workflow" | cut -d: -f1)
  prepare_line=$(grep -nF 'name: Prepare locked livepatch CI tools' \
    "$workflow" | head -n1 | cut -d: -f1)
  [[ -n "$resume_line" && -n "$checkout_line" && -n "$prepare_line" ]]
  ((resume_line < checkout_line && checkout_line < prepare_line))
  [[ $(grep -Fc "core.setOutput('provenance', JSON.stringify(provenance))" \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'name: Record qualification resume provenance' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'qualification resume inputs must be supplied all or none' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'if (supplied === 0)' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'if (supplied !== Object.keys(inputs).length)' "$workflow") -eq 1 ]]
  [[ $(grep -Fc "!/^[1-9][0-9]*$/.test(inputs.runId)" "$workflow") -eq 1 ]]
  [[ $(grep -Fc "!/^[0-9a-f]{40}$/.test(inputs.sourceRevision)" "$workflow") -eq 1 ]]
  [[ $(grep -Fc "!/^[0-9a-f]{64}$/.test(inputs.planSha256)" "$workflow") -eq 1 ]]
  [[ $(grep -Fc "!/^[0-9a-f]{64}$/.test(inputs.captureSha256)" "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'EXPECTED_REPOSITORY: vpsfreecz/vpsadminos' "$workflow") -eq 3 ]]
  [[ $(grep -Fc "workflow_id: 'livepatch-qualification.yml'" "$workflow") -eq 1 ]]
  [[ $(grep -Fc '/attempts/{attempt_number}' "$workflow") -eq 2 ]]
  [[ $(grep -Fc '/actions/runs/{run_id}/artifacts' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'source run contains a successful ordinary row outside the resume interface' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'github-token: ${{ github.token }}' "$workflow") -eq 4 ]]
  [[ $(grep -Fc 'repository: ${{ github.repository }}' "$workflow") -eq 3 ]]
  [[ $(grep -Fc "run-id: \${{ inputs['resume-source-run-id'] }}" "$workflow") -eq 3 ]]
  [[ $(grep -Fc "ref: \${{ inputs['resume-source-revision'] || github.sha }}" \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'ref: ${{ needs.discover.outputs.source-revision }}' "$workflow") -eq 4 ]]
  [[ $(grep -Fc 'fail-fast: false' "$workflow") -eq 2 ]]
  [[ $(grep -Fc 'fail-fast: true' "$workflow") -eq 0 ]]
  [[ $(grep -Fc 'needs.affected-regression.result' "$workflow") -eq 1 ]]
  [[ $(grep -Fc '/results/new' "$workflow") -eq 1 ]]
  [[ $(grep -Fc '/results/imported' "$workflow") -eq 2 ]]
  [[ $(grep -Fc '.plannedRows == 84' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'needs.discover.outputs.resume-mode != '\''true'\''' "$workflow") -eq 2 ]]
  [[ $(grep -Fc 'needs.discover.outputs.resume-mode == '\''true'\''' "$workflow") -eq 2 ]]
  [[ $(grep -Fc 'actions/download-artifact@v7' "$workflow") -eq 0 ]]
  [[ $(grep -Fc 'actions/download-artifact@v8' "$workflow") -eq 12 ]]

  [[ $(grep -Fc 'if ! git cat-file -e "$base^{commit}" 2>/dev/null; then' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'git fetch --no-tags --depth=1 origin "$base"' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'git cat-file -e "$base^{commit}"' "$workflow") -eq 2 ]]
  for field in event base head sourceRevision changedPathsSha256; do
    [[ $(grep -Fc "${field}: \$${field}" "$workflow") -eq 1 ]]
  done
  [[ $(grep -Fc 'tools/livepatch/ci-workspace.sh prepare' "$workflow") -eq 5 ]]
  [[ $(grep -Fc 'tools/livepatch/ci-workspace.sh cleanup' "$workflow") -eq 5 ]]
  [[ $(grep -Fc -- '--directory "$LIVEPATCH_CI_WORKSPACE"' "$workflow") -eq 5 ]]
  [[ $(grep -Fc 'id: workspace' "$workflow") -eq 5 ]]
  for job in discover capture qualify; do
    [[ $(grep -Fc "LIVEPATCH_CI_JOB: $job" "$workflow") -eq 2 ]]
  done
  [[ $(grep -Fc 'LIVEPATCH_CI_JOB: results' "$workflow") -eq 4 ]]
  if grep -Eq '\$RUNNER_TEMP/livepatch-(discovery|input|capture|results)|\$\{\{ runner[.]temp \}\}/livepatch-(discovery|input|capture|results)' \
    "$workflow"; then
    echo 'workflow retains an active fixed livepatch scratch path' >&2
    exit 1
  fi

  [[ $(grep -Fc 'uses: ./.github/actions/prepare-test-state' "$workflow") -eq 2 ]]
  [[ $(grep -Fc 'uses: ./.github/actions/cleanup-test-state' "$workflow") -eq 2 ]]
  [[ $(grep -Fc 'LIVEPATCH_PROFILE_STATE: ${{ steps.prepare-profile.outputs.state-directory }}/profile' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'path: ${{ steps.prepare-profile.outputs.state-directory }}/profile' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'state-directory: ${{ steps.prepare-profile.outputs.state-directory }}' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'steps.cleanup-profile.outcome == '\''success'\''' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'steps.upload-result.outcome == '\''success'\''' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'TEST_RUNNER_STATE_DIR: ${{ steps.prepare-tests.outputs.state-directory }}' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'state-directory: ${{ steps.prepare-tests.outputs.state-directory }}' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'prepare-outcome: ${{ steps.prepare-tests.outcome }}' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'test-outcome: ${{ steps.run-tests.outcome }}' "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'upload-outcome: ${{ steps.upload-test-logs.outcome }}' "$workflow") -eq 1 ]]
  [[ $(grep -Ec '^[[:space:]]*\$\{\{ steps[.]workspace[.]outputs[.]directory \}\}$' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Ec '^[[:space:]]*path: \$\{\{ steps[.]workspace[.]outputs[.]directory \}\}/capture$' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Ec '^[[:space:]]*path: \$\{\{ steps[.]workspace[.]outputs[.]directory \}\}/results$' \
    "$workflow") -eq 1 ]]

  capture_plan_line=$(grep -nF 'name: Download the current-run qualification plan' \
    "$workflow" | cut -d: -f1)
  capture_resume_line=$(grep -nF 'name: Download the current-run resume capture' \
    "$workflow" | cut -d: -f1)
  capture_resume_condition_line=$(grep -nF \
    "if: \${{ needs.discover.outputs.resume-mode == 'true' }}" "$workflow" \
    | awk -F: -v start="$capture_resume_line" '$1 > start { print $1; exit }')
  capture_resume_name_line=$(grep -nF \
    'name: livepatch-capture-${{ github.run_id }}-${{ github.run_attempt }}' \
    "$workflow" \
    | awk -F: -v start="$capture_resume_line" '$1 > start { print $1; exit }')
  capture_resume_path_line=$(grep -nF \
    'path: ${{ steps.workspace.outputs.directory }}/input/capture' "$workflow" \
    | awk -F: -v start="$capture_resume_line" '$1 > start { print $1; exit }')
  capture_line=$(grep -nF 'name: Capture one dynamic producer identity set' \
    "$workflow" | cut -d: -f1)
  capture_input_line=$(grep -nF \
    'capture="$LIVEPATCH_CI_WORKSPACE/input/capture/capture.json"' \
    "$workflow" | cut -d: -f1)
  evidence_input_line=$(grep -nF \
    'evidence="$LIVEPATCH_CI_WORKSPACE/input/capture/evidence"' \
    "$workflow" | head -n1 | cut -d: -f1)
  capture_hash_line=$(grep -nF \
    '[[ $(sha256sum "$capture" | cut -d'"'"' '"'"' -f1) == "$RESUME_CAPTURE_SHA256" ]]' \
    "$workflow" | cut -d: -f1)
  publish_line=$(grep -nF 'name: Publish and prove captured producer closures' \
    "$workflow" | cut -d: -f1)
  coverage_line=$(grep -nF 'name: Decide ordinary workload coverage from exact tuples' \
    "$workflow" | cut -d: -f1)
  upload_line=$(grep -nF 'name: Upload captured modules and realization evidence' \
    "$workflow" | cut -d: -f1)
  [[ -n "$capture_plan_line" && -n "$capture_resume_line" && -n "$capture_line" ]]
  [[ -n "$capture_resume_condition_line" && -n "$capture_resume_name_line" ]]
  [[ -n "$capture_resume_path_line" ]]
  ((capture_plan_line < capture_resume_line))
  ((capture_resume_line < capture_resume_condition_line))
  ((capture_resume_condition_line < capture_resume_name_line))
  ((capture_resume_name_line < capture_resume_path_line))
  ((capture_resume_path_line < capture_line))
  [[ $(grep -Fc 'name: livepatch-capture-${{ github.run_id }}-${{ github.run_attempt }}' \
    "$workflow") -eq 5 ]]
  [[ $(grep -Fc 'path: ${{ steps.workspace.outputs.directory }}/input/capture' \
    "$workflow") -eq 3 ]]
  [[ $(grep -Fc '!${{ steps.workspace.outputs.directory }}/resume/**' \
    "$workflow") -eq 1 ]]
  [[ -n "$capture_input_line" && -n "$evidence_input_line" && -n "$capture_hash_line" ]]
  ((capture_line < capture_input_line && capture_input_line < capture_hash_line))
  ((capture_line < evidence_input_line && evidence_input_line < capture_hash_line))
  [[ -n "$publish_line" && -n "$coverage_line" && -n "$upload_line" ]]
  ((capture_line < publish_line && publish_line < coverage_line && coverage_line < upload_line))
  [[ $(grep -Fc 'expected_members=$(jq -er '"'"'.counts.capturedMembers'"'"' "$capture")' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'jq -er '"'"'.sets[].members[].identity.producer'"'"' "$capture"' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'jq -er '"'"'.sets[].members[].audit.requisites[]'"'"' "$capture"' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'nix-store --query --requisites "${producers[@]}"' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'nix-copy-closure --to push@cache.int.vpsadminos.org "${producers[@]}"' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'sudo push-ci-generation "$branch" "$producer"' \
    "$workflow") -eq 1 ]]
  [[ $(grep -Fc "nix store verify \\" "$workflow") -eq 1 ]]
  [[ $(grep -Fc "nix store dump-path \\" "$workflow") -eq 1 ]]
  [[ $(grep -Fc 'nix store dump-path "$producer"' "$workflow") -eq 1 ]]
}

capture_interface
run_profile_interface
ci_workspace_interface
resume_import_interface
resume_jobs_pagination_interface
workflow_interface

echo "livepatch capture verifier matrix passed"

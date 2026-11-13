#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: tools/livepatch/capture.sh --plan FILE --output FILE --evidence-dir DIR" >&2
  exit 2
}

plan=
output=
evidence_dir=
while (($#)); do
  case "$1" in
    --evidence-dir)
      (($# >= 2)) || usage
      evidence_dir=$2
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
    *) usage ;;
  esac
done

[[ -n "$plan" && -n "$output" && -n "$evidence_dir" ]] || usage
[[ -f "$plan" && ! -L "$plan" ]] || {
  echo "plan must be a regular non-symlink file" >&2
  exit 1
}
[[ ! -e "$output" && ! -L "$output" ]] || {
  echo "refusing pre-existing capture output: $output" >&2
  exit 1
}
[[ ! -e "$evidence_dir" && ! -L "$evidence_dir" ]] || {
  echo "refusing pre-existing evidence directory: $evidence_dir" >&2
  exit 1
}
mkdir -- "$evidence_dir"

work=$(mktemp -d "${TMPDIR:-/tmp}/livepatch-capture.XXXXXX")
output_tmp=$(mktemp "$(dirname -- "$output")/.livepatch-capture.XXXXXX")
cleanup() {
  rm -rf -- "$work"
  rm -f -- "$output_tmp"
}
trap cleanup EXIT HUP INT TERM

tools/livepatch/discover.sh \
  --input "$plan" \
  --plan "$work/validated-plan.json" \
  --matrix "$work/matrix.json"
cmp -- "$plan" "$work/validated-plan.json"

source_revision=$(git rev-parse HEAD)
flake_lock_sha256=$(sha256sum flake.lock | cut -d' ' -f1)
plan_source=$(jq -er '.sourceRevision // empty' "$plan")
[[ "$plan_source" == "$source_revision" ]] || {
  echo "plan source revision does not match HEAD" >&2
  exit 1
}

jq -n \
  --arg sourceRevision "$source_revision" \
  --arg flakeLockSha256 "$flake_lock_sha256" \
  '{
    schemaVersion: 1,
    sourceRevision: $sourceRevision,
    flakeLockSha256: $flakeLockSha256,
    selectedSets: 0,
    sets: [],
    counts: { plannedMembers: 0, capturedMembers: 0 },
    rawBuildLogIdentity: "per-realization-only"
  }' >"$work/capture.json"

while IFS= read -r set; do
  set_id=$(jq -er '.id' <<<"$set")
  members_file="$work/members.json"
  printf '[]\n' >"$members_file"

  while IFS= read -r member; do
    release=$(jq -er '.release' <<<"$member")
    producer_attr=$(jq -er '.producerAttr' <<<"$member")
    mapfile -t outputs < <(nix build --no-link --print-out-paths ".#${producer_attr}")
    ((${#outputs[@]} == 1)) || {
      echo "producer attribute $producer_attr returned ${#outputs[@]} outputs" >&2
      exit 1
    }
    producer=$(readlink -e -- "${outputs[0]}")
    [[ -d "$producer" ]] || {
      echo "producer output is unavailable: $producer" >&2
      exit 1
    }

    structured="$producer/share/vpsadminos-livepatch"
    manifest="$structured/manifest.json"
    inspection="$structured/inspection.json"
    closure="$structured/closure.json"
    expected="$structured/expected-inspection.json"
    raw="$producer/livepatch-evidence"
    for path in "$manifest" "$inspection" "$closure" "$expected" \
      "$structured/framework.patch" "$structured/generated-header.h" \
      "$raw/build.log" "$raw/changed-objects.txt"; do
      [[ -f "$path" && ! -L "$path" ]] || {
        echo "producer evidence is missing or unsafe: $path" >&2
        exit 1
      }
    done

    install_path=$(jq -er '.installPath' "$manifest")
    module_name=$(jq -er '.moduleName' "$manifest")
    module=$(readlink -e -- "$producer/$install_path")
    [[ -f "$module" ]] || {
      echo "manifest module is unavailable: $producer/$install_path" >&2
      exit 1
    }
    module_sha256=$(sha256sum "$module" | cut -d' ' -f1)
    manifest_sha256=$(sha256sum "$manifest" | cut -d' ' -f1)
    inspection_sha256=$(sha256sum "$inspection" | cut -d' ' -f1)
    closure_sha256=$(sha256sum "$closure" | cut -d' ' -f1)
    expected_sha256=$(sha256sum "$expected" | cut -d' ' -f1)
    framework_sha256=$(sha256sum "$structured/framework.patch" | cut -d' ' -f1)
    generated_header_sha256=$(sha256sum "$structured/generated-header.h" | cut -d' ' -f1)
    changed_objects_sha256=$(sha256sum "$raw/changed-objects.txt" | cut -d' ' -f1)
    build_log_sha256=$(sha256sum "$raw/build.log" | cut -d' ' -f1)
    target_id=$(jq -er '.kernelTarget.id' "$manifest")
    input_digest=$(jq -er '.inputDigest' "$manifest")
    vermagic=$(jq -er '.module.vermagic' "$inspection")
    deriver=$(nix-store --query --deriver "$producer")
    [[ "$deriver" == /nix/store/*.drv ]] || {
      echo "producer deriver is invalid: $deriver" >&2
      exit 1
    }
    nix-store --query --requisites "$producer" | LC_ALL=C sort -u >"$work/requisites"
    [[ -s "$work/requisites" ]] || {
      echo "producer requisites are empty" >&2
      exit 1
    }

    jq -e \
      --arg release "$release" \
      --arg moduleName "$module_name" \
      --arg moduleSha256 "$module_sha256" '
        .schemaVersion == 1
        and .batch.release == $release
        and .mode == "additive"
        and .moduleName == $moduleName
        and (.inputDigest | test("^[0-9a-f]{64}$"))
      ' "$manifest" >/dev/null
    jq -e \
      --arg moduleName "$module_name" \
      --arg moduleSha256 "$module_sha256" \
      --slurpfile expected "$expected" '
        def canonical_callbacks: sort_by([.kind, .object, .symbol]);

        .schemaVersion == 1
        and .module.name == $moduleName
        and .module.sha256 == $moduleSha256
        and .module.livepatch == "Y"
        and .buildInvocation.nonReplaceRequested == true
        and ([.functions[] | {object, symbol, sympos}] == [$expected[0].functions[] | {object, symbol, sympos}])
        and .imports == $expected[0].imports
        and .relocations == $expected[0].relocations
        and (.callbacks | canonical_callbacks) == ($expected[0].callbacks | canonical_callbacks)
        and .states == $expected[0].states
        and .framework == $expected[0].framework
      ' "$inspection" >/dev/null
    jq -e '.schemaVersion == 1 and .matches == true and .mismatches == {}' "$closure" >/dev/null

    member_evidence="$evidence_dir/$release"
    mkdir -- "$member_evidence"
    cp -a -- "$structured" "$member_evidence/structured"
    cp -a -- "$raw" "$member_evidence/raw"
    cp -- "$work/requisites" "$member_evidence/requisites.txt"

    jq -n \
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
      --arg sourceRevision "$source_revision" \
      --arg flakeLockSha256 "$flake_lock_sha256" \
      --arg deriver "$deriver" \
      --arg expectedInspectionSha256 "$expected_sha256" \
      --arg frameworkSha256 "$framework_sha256" \
      --arg generatedHeaderSha256 "$generated_header_sha256" \
      --arg changedObjectsSha256 "$changed_objects_sha256" \
      --arg buildLogSha256 "$build_log_sha256" \
      --rawfile requisites "$work/requisites" '
        {
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
            expectedInspectionSha256: $expectedInspectionSha256,
            frameworkSha256: $frameworkSha256,
            generatedHeaderSha256: $generatedHeaderSha256,
            changedObjectsSha256: $changedObjectsSha256,
            buildLogSha256: $buildLogSha256,
            buildLogIdentity: "per-realization-only"
          }
        }
      ' >"$work/member.json"
    jq --slurpfile member "$work/member.json" '. + [$member[0]]' \
      "$members_file" >"$members_file.next"
    mv -T -- "$members_file.next" "$members_file"
  done < <(jq -c '.members[]' <<<"$set")

  jq -n --arg id "$set_id" --slurpfile members "$members_file" \
    '{id: $id, members: $members[0]}' >"$work/set.json"
  jq --slurpfile set "$work/set.json" '
    .sets += [$set[0]]
    | .selectedSets = (.sets | length)
    | .counts.capturedMembers = ([.sets[].members | length] | add // 0)
  ' "$work/capture.json" >"$work/capture.next"
  mv -T -- "$work/capture.next" "$work/capture.json"
done < <(jq -c '.sets[]' "$plan")

planned_members=$(jq -er '.counts.plannedMembers' "$plan")
jq --argjson plannedMembers "$planned_members" \
  '.counts.plannedMembers = $plannedMembers' "$work/capture.json" >"$output_tmp"

tools/livepatch/verify.sh --plan "$plan" --capture "$output_tmp" >/dev/null
chmod 0644 "$output_tmp"
mv -T -- "$output_tmp" "$output"
trap - EXIT HUP INT TERM
rm -rf -- "$work"

#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: tools/livepatch/verify.sh --plan FILE --capture FILE
       tools/livepatch/verify.sh --plan FILE --capture FILE --row-id ID --result FILE
       tools/livepatch/verify.sh --plan FILE --results-dir DIR --output FILE
EOF
  exit 2
}

plan=
capture=
row_id=
result=
results_dir=
output=
while (($#)); do
  case "$1" in
    --capture)
      (($# >= 2)) || usage
      capture=$2
      shift 2
      ;;
    --plan)
      (($# >= 2)) || usage
      plan=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || usage
      output=$2
      shift 2
      ;;
    --result)
      (($# >= 2)) || usage
      result=$2
      shift 2
      ;;
    --row-id)
      (($# >= 2)) || usage
      row_id=$2
      shift 2
      ;;
    --results-dir)
      (($# >= 2)) || usage
      results_dir=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$plan" ]] || usage
campaign=false
if [[ -n "$results_dir" || -n "$output" ]]; then
  [[ -n "$results_dir" && -n "$output" ]] || usage
  [[ -z "$capture" && -z "$row_id" && -z "$result" ]] || usage
  campaign=true
else
  [[ -n "$capture" && -z "$output" ]] || usage
  if [[ -n "$row_id" || -n "$result" ]]; then
    [[ -n "$row_id" && -n "$result" ]] || usage
  fi
fi
for input in "$plan"; do
  [[ -f "$input" && ! -L "$input" ]] || {
    echo "input must be a regular non-symlink file: $input" >&2
    exit 1
  }
done

verify_result_file() {
  local selected_row_id=$1
  local selected_result=$2

  [[ -f "$selected_result" && ! -L "$selected_result" ]] || {
    echo "result must be a regular non-symlink file" >&2
    return 1
  }
  jq -e --arg rowId "$selected_row_id" --slurpfile plan "$plan" '
    ([ $plan[0].rows[] | select(.rowId == $rowId) ]
      | if length == 1 then .[0] else null end) as $row
    | $row != null
    and .schemaVersion == 1
    and .rowId == $rowId
    and (.accepted | type == "boolean")
    and (.runnerStatus | type == "number" and floor == .)
    and (.validator | type == "object")
    and .setId == $row.setId
    and .profileId == $row.profileId
    and (
      if $row.scope == "set" then
        $row.oracleIds == []
        and $row.validator == "builtin/generic-livepatch-safety-v1"
        and .validator.id == "builtin/generic-livepatch-safety-v1"
        and (.semantic | type == "object")
        and .semantic.schemaVersion == 1
        and .semantic.contract == "generic-livepatch-safety-v1"
        and .semantic.rowId == $row.rowId
        and .semantic.setId == $row.setId
        and .semantic.profileId == $row.profileId
        and .semantic.role == $row.role
        and .semantic.platform.id == $row.platform.id
      else
        true
      end
    )
  ' "$selected_result" >/dev/null
}

if $campaign; then
  [[ -d "$results_dir" && ! -L "$results_dir" ]] || {
    echo "results directory must be a non-symlink directory" >&2
    exit 1
  }
  [[ ! -e "$output" && ! -L "$output" ]] || {
    echo "campaign output already exists" >&2
    exit 1
  }
  mapfile -t receipts < <(find "$results_dir" -type f -name result.json -print | LC_ALL=C sort)
  expected=$(jq -er '.counts.matrixRows' "$plan")
  [[ ${#receipts[@]} -eq "$expected" ]] || {
    echo "receipt count does not match the plan" >&2
    exit 1
  }
  for receipt in "${receipts[@]}"; do
    receipt_row=$(jq -er '.rowId' "$receipt")
    verify_result_file "$receipt_row" "$receipt"
  done
  jq -s -e --slurpfile plan "$plan" '
    length == $plan[0].counts.matrixRows
    and (map(.rowId) | unique | length) == length
    and (map(.rowId) | sort) == ($plan[0].matrix.include | map(.rowId) | sort)
    and all(
      .schemaVersion == 1
      and .accepted == true
      and .runnerStatus == 0
      and .validator.status == "accepted"
    )
  ' "${receipts[@]}" >/dev/null
  output_tmp=$(mktemp "$(dirname -- "$output")/.livepatch-results.XXXXXX")
  trap 'rm -f -- "$output_tmp"' EXIT HUP INT TERM
  jq -s --slurpfile plan "$plan" '{
    schemaVersion: 1,
    accepted: true,
    plannedRows: $plan[0].counts.matrixRows,
    receipts: sort_by(.rowId)
  }' "${receipts[@]}" >"$output_tmp"
  jq -e '.schemaVersion == 1 and .accepted == true and .plannedRows == (.receipts | length)' \
    "$output_tmp" >/dev/null
  mv -T -- "$output_tmp" "$output"
  trap - EXIT HUP INT TERM
  exit 0
fi

[[ -f "$capture" && ! -L "$capture" ]] || {
  echo "input must be a regular non-symlink file: $capture" >&2
  exit 1
}

jq -e --slurpfile plan "$plan" '
  def sha: type == "string" and test("^[0-9a-f]{64}$");
  def nonempty: type == "string" and length > 0;
  . as $capture
  | .schemaVersion == 1
  and .rawBuildLogIdentity == "per-realization-only"
  and (.sourceRevision | nonempty)
  and (.flakeLockSha256 | sha)
  and (.sets | type == "array")
  and (.selectedSets == (.sets | length))
  and (.selectedSets == $plan[0].selectedSets)
  and (.counts.plannedMembers == $plan[0].counts.plannedMembers)
  and (.counts.capturedMembers == ([.sets[].members | length] | add // 0))
  and (.counts.capturedMembers == .counts.plannedMembers)
  and ([.sets[].id] == [$plan[0].sets[].id])
  and ([.sets[].members[].release] == [$plan[0].sets[].members[].release])
  and (.sets | all(.members | all(
    (.identity | type == "object")
    and (.identity | keys | sort) == [
      "closureSha256", "flakeLockSha256", "inputDigest", "inspectionSha256",
      "manifestSha256", "module", "moduleName", "moduleSha256", "producer",
      "sourceRevision", "targetId", "vermagic"
    ]
    and (.identity.producer | nonempty)
    and (.identity.module | nonempty)
    and (.identity.moduleName | nonempty)
    and (.identity.targetId | nonempty)
    and (.identity.vermagic | nonempty)
    and (.identity.moduleSha256 | sha)
    and (.identity.inputDigest | sha)
    and (.identity.manifestSha256 | sha)
    and (.identity.inspectionSha256 | sha)
    and (.identity.closureSha256 | sha)
    and (.identity.sourceRevision == $plan[0].sourceRevision)
    and (.identity.flakeLockSha256 == $capture.flakeLockSha256)
    and (.audit.deriver | nonempty)
    and (.audit.requisites | type == "array" and length > 0)
    and (.audit.buildLogIdentity == "per-realization-only")
    and (.audit.buildLogSha256 | sha)
  )))
' "$capture" >/dev/null

source_revision=$(git rev-parse HEAD)
flake_lock_sha256=$(sha256sum flake.lock | cut -d' ' -f1)
[[ $(jq -er '.sourceRevision' "$capture") == "$source_revision" ]]
[[ $(jq -er '.flakeLockSha256' "$capture") == "$flake_lock_sha256" ]]

while IFS= read -r member; do
  producer=$(jq -er '.identity.producer' <<<"$member")
  module=$(jq -er '.identity.module' <<<"$member")
  nix-store --option fallback false --realise "$producer" >/dev/null
  [[ -d "$producer" && -f "$module" ]] || {
    echo "captured producer/module is unavailable" >&2
    exit 1
  }
  structured="$producer/share/vpsadminos-livepatch"
  raw="$producer/livepatch-evidence"
  [[ $(sha256sum "$module" | cut -d' ' -f1) == $(jq -er '.identity.moduleSha256' <<<"$member") ]]
  [[ $(sha256sum "$structured/manifest.json" | cut -d' ' -f1) == $(jq -er '.identity.manifestSha256' <<<"$member") ]]
  [[ $(sha256sum "$structured/inspection.json" | cut -d' ' -f1) == $(jq -er '.identity.inspectionSha256' <<<"$member") ]]
  [[ $(sha256sum "$structured/closure.json" | cut -d' ' -f1) == $(jq -er '.identity.closureSha256' <<<"$member") ]]
  [[ $(sha256sum "$raw/build.log" | cut -d' ' -f1) == $(jq -er '.audit.buildLogSha256' <<<"$member") ]]
  jq -e --arg name "$(jq -er '.identity.moduleName' <<<"$member")" \
    --arg digest "$(jq -er '.identity.inputDigest' <<<"$member")" \
    --arg target "$(jq -er '.identity.targetId' <<<"$member")" '
      .schemaVersion == 1
      and .mode == "additive"
      and .moduleName == $name
      and .inputDigest == $digest
      and .kernelTarget.id == $target
    ' "$structured/manifest.json" >/dev/null
  jq -e --arg name "$(jq -er '.identity.moduleName' <<<"$member")" \
    --arg sha "$(jq -er '.identity.moduleSha256' <<<"$member")" \
    --arg vermagic "$(jq -er '.identity.vermagic' <<<"$member")" '
      .schemaVersion == 1
      and .buildInvocation.nonReplaceRequested == true
      and .module.name == $name
      and .module.sha256 == $sha
      and .module.vermagic == $vermagic
    ' "$structured/inspection.json" >/dev/null
  jq -e '.schemaVersion == 1 and .matches == true and .mismatches == {}' \
    "$structured/closure.json" >/dev/null
  [[ $(nix-store --query --deriver "$producer") == $(jq -er '.audit.deriver' <<<"$member") ]]
  diff -u \
    <(nix-store --query --requisites "$producer" | LC_ALL=C sort -u) \
    <(jq -r '.audit.requisites[]' <<<"$member")
done < <(jq -c '.sets[].members[]' "$capture")

if [[ -n "$row_id" ]]; then
  verify_result_file "$row_id" "$result"
fi

jq -n \
  --arg planSha256 "$(sha256sum "$plan" | cut -d' ' -f1)" \
  --arg captureSha256 "$(sha256sum "$capture" | cut -d' ' -f1)" \
  '{schemaVersion: 1, verified: true, planSha256: $planSha256, captureSha256: $captureSha256}'

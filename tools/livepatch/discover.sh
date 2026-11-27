#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: tools/livepatch/discover.sh --plan FILE --matrix FILE [--system SYSTEM]
       tools/livepatch/discover.sh --input FILE --plan FILE --matrix FILE
         [--changed-paths FILE | --kernel-version VERSION ...]
EOF
  exit 2
}

plan_output=
matrix_output=
input=
system=x86_64-linux
changed_paths=
kernel_versions=()

while (($#)); do
  case "$1" in
    --input)
      (($# >= 2)) || usage
      input=$2
      shift 2
      ;;
    --changed-paths)
      (($# >= 2)) || usage
      changed_paths=$2
      shift 2
      ;;
    --kernel-version)
      (($# >= 2)) || usage
      kernel_versions+=("$2")
      shift 2
      ;;
    --matrix)
      (($# >= 2)) || usage
      matrix_output=$2
      shift 2
      ;;
    --plan)
      (($# >= 2)) || usage
      plan_output=$2
      shift 2
      ;;
    --system)
      (($# >= 2)) || usage
      system=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$plan_output" && -n "$matrix_output" ]] || usage
[[ -z "$changed_paths" || ${#kernel_versions[@]} -eq 0 ]] || usage
[[ "$system" =~ ^[a-z0-9_+-]+-linux$ ]] || {
  echo "invalid Nix system: $system" >&2
  exit 1
}

for output in "$plan_output" "$matrix_output"; do
  parent=$(dirname -- "$output")
  [[ -d "$parent" ]] || {
    echo "output parent does not exist: $parent" >&2
    exit 1
  }
  [[ ! -e "$output" && ! -L "$output" ]] || {
    echo "refusing pre-existing output: $output" >&2
    exit 1
  }
done

plan_tmp=$(mktemp "$(dirname -- "$plan_output")/.livepatch-plan.XXXXXX")
matrix_tmp=$(mktemp "$(dirname -- "$matrix_output")/.livepatch-matrix.XXXXXX")
cleanup() {
  rm -f -- "$plan_tmp" "$matrix_tmp"
}
trap cleanup EXIT HUP INT TERM

if [[ -n "$input" ]]; then
  [[ -f "$input" && ! -L "$input" ]] || {
    echo "plan input must be a regular non-symlink file" >&2
    exit 1
  }
  cp -- "$input" "$plan_tmp"
else
  nix eval --json "path:.#livepatchQualification.${system}" >"$plan_tmp"
  source_revision=$(git rev-parse HEAD)
  jq --arg sourceRevision "$source_revision" \
    '.sourceRevision = $sourceRevision' "$plan_tmp" >"$plan_tmp.source"
  mv -T -- "$plan_tmp.source" "$plan_tmp"
fi

selected_versions=()
if [[ -n "$changed_paths" ]]; then
  [[ -f "$changed_paths" && ! -L "$changed_paths" ]] || {
    echo "changed-path input must be a regular non-symlink file" >&2
    exit 1
  }

  declare -A changed_kernels=()
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    if [[ "$path" =~ ^os/livepatches/batches/([^/]+)/([1-9][0-9]*)/(.+)$ ]]; then
      kernel_version=${BASH_REMATCH[1]}
      [[ "$kernel_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "malformed livepatch batch path: $path" >&2
        exit 1
      }
      changed_kernels["$kernel_version"]=1
    elif [[ "$path" == os/livepatches/batches/* ]]; then
      echo "malformed livepatch batch path: $path" >&2
      exit 1
    fi
  done <"$changed_paths"

  if ((${#changed_kernels[@]})); then
    mapfile -t selected_versions < <(printf '%s\n' "${!changed_kernels[@]}" | LC_ALL=C sort)
  fi
elif ((${#kernel_versions[@]})); then
  declare -A requested_kernels=()
  for kernel_version in "${kernel_versions[@]}"; do
    [[ "$kernel_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "invalid kernel version: $kernel_version" >&2
      exit 1
    }
    [[ -z "${requested_kernels[$kernel_version]:-}" ]] || {
      echo "duplicate requested kernel version: $kernel_version" >&2
      exit 1
    }
    requested_kernels["$kernel_version"]=1
    selected_versions+=("$kernel_version")
  done
fi

if [[ -n "$changed_paths" || ${#kernel_versions[@]} -gt 0 ]]; then
  selected_json=$(printf '%s\n' "${selected_versions[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq --argjson selectedVersions "$selected_json" '
    . as $plan
    | [
        $selectedVersions[] as $kernelVersion
        | [$plan.sets[] | select(.kernelVersion == $kernelVersion)] as $matches
        | if ($matches | length) == 1 then
            $matches[0]
          elif ($matches | length) == 0 then
            error("requested kernel is absent from the canonical plan: \($kernelVersion)")
          else
            error("canonical plan has duplicate sets for kernel: \($kernelVersion)")
          end
      ] as $sets
    | [$sets[].id] as $setIds
    | [$sets[].members[].release] as $memberReleases
    | [.releases[] | select(.release as $release | $memberReleases | index($release))] as $releases
    | [.rows[] | select(.setId as $setId | $setIds | index($setId))] as $rows
    | [.coverage[] | select(.setId as $setId | $setIds | index($setId))] as $coverage
    | [.matrix.include[] | select(.setId as $setId | $setIds | index($setId))] as $matrix
    | .sets = $sets
    | .releases = $releases
    | .rows = $rows
    | .coverage = $coverage
    | .matrix.include = $matrix
    | .selectedSets = ($sets | length)
    | .dormant = (($sets | length) == 0)
    | .counts.catalogReleases = ($releases | length)
    | .counts.normalizedReleases = ($releases | length)
    | .counts.plannedMembers = ([$sets[].members[]] | length)
    | .counts.requiredProfilePlatformTuples = ([$rows[] | select(.scope == "set")] | length)
    | .counts.activeOracles = ([$sets[].oracleIds[]] | length)
    | .counts.coverageTuples = ($coverage | length)
    | .counts.plannedRows = ($rows | length)
    | .counts.matrixRows = ($matrix | length)
  ' "$plan_tmp" >"$plan_tmp.selected"
  mv -T -- "$plan_tmp.selected" "$plan_tmp"
fi

jq -e '
  def nonempty: type == "string" and length > 0;
  def stable_id: nonempty and test("^[a-z0-9][a-z0-9._:/-]*[a-z0-9]$|^[a-z0-9]$");
  def compact_row:
    type == "object"
    and (keys | sort) == [
      "expectedOutcome", "profileId", "rowId", "runnerClass", "setId", "timeoutClass"
    ]
    and (.rowId | stable_id)
    and (.setId | stable_id)
    and (.profileId | stable_id)
    and (.runnerClass | nonempty)
    and (.timeoutClass | nonempty)
    and (.expectedOutcome | nonempty);
  .schemaVersion == 1
  and (.dormant | type == "boolean")
  and (.sourceRevision | nonempty)
  and (.system | nonempty)
  and (.selectedSets | type == "number" and floor == . and . >= 0)
  and (.sets | type == "array")
  and (.releases | type == "array")
  and (.rows | type == "array")
  and (.coverage | type == "array")
  and (.matrix | type == "object")
  and (.matrix.include | type == "array" and length <= 256 and all(compact_row))
  and (.counts | type == "object")
  and (.counts.catalogReleases == (.releases | length))
  and (.counts.normalizedReleases == (.releases | length))
  and (.counts.plannedMembers == ([.sets[].members | length] | add // 0))
  and (.counts.plannedRows == (.rows | length))
  and (.counts.matrixRows == (.matrix.include | length))
  and (.selectedSets == (.sets | length))
  and (([.sets[].id] | unique | length) == (.sets | length))
  and (([.rows[].rowId] | unique | length) == (.rows | length))
  and (([.matrix.include[].rowId] | sort) == ([.rows[].rowId] | sort))
  and (
    if .selectedSets == 0 then
      .dormant == true
      and (.sets | length) == 0
      and (.releases | length) == 0
      and (.rows | length) == 0
      and (.coverage | length) == 0
    else
      .dormant == false
      and (.sets | all(
        (.id | stable_id)
        and (.members | type == "array" and length > 0)
        and (.oracleIds | type == "array")
      ))
      and (.counts.coverageTuples == (.coverage | length))
    end
  )
' "$plan_tmp" >/dev/null

jq -c '{include: .matrix.include}' "$plan_tmp" >"$matrix_tmp"
[[ $(wc -c <"$matrix_tmp") -lt 65536 ]] || {
  echo "compact matrix exceeds 64 KiB" >&2
  exit 1
}

chmod 0644 "$plan_tmp" "$matrix_tmp"
mv -T -- "$plan_tmp" "$plan_output"
mv -T -- "$matrix_tmp" "$matrix_output"
trap - EXIT HUP INT TERM

#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: tools/livepatch/discover.sh --plan FILE --matrix FILE [--system SYSTEM]
       tools/livepatch/discover.sh --input FILE --plan FILE --matrix FILE
EOF
  exit 2
}

plan_output=
matrix_output=
input=
system=x86_64-linux

while (($#)); do
  case "$1" in
    --input)
      (($# >= 2)) || usage
      input=$2
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
        and (.oracleIds | type == "array" and length > 0)
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

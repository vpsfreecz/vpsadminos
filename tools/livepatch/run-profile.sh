#!/usr/bin/env bash

set -euo pipefail

[[ -n ${BASH_VERSION:-} ]] || {
  echo "Bash interpreter is unavailable" >&2
  exit 1
}
bash_path=$BASH
[[ $bash_path == /* && -x $bash_path ]] || {
  echo "Bash interpreter path is not an absolute executable: $bash_path" >&2
  exit 1
}

usage() {
  echo "usage: tools/livepatch/run-profile.sh --plan FILE --capture FILE [--evidence-dir DIR] --row-id ID --state-dir DIR" >&2
  exit 2
}

plan=
capture=
evidence_dir=
row_id=
state_dir=
while (($#)); do
  case "$1" in
    --capture)
      (($# >= 2)) || usage
      capture=$2
      shift 2
      ;;
    --evidence-dir)
      (($# >= 2)) || usage
      evidence_dir=$2
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
    --state-dir)
      (($# >= 2)) || usage
      state_dir=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ -n "$plan" && -n "$capture" && -n "$row_id" && -n "$state_dir" ]] || usage
if [[ -n "$evidence_dir" ]]; then
  [[ -d "$evidence_dir" && ! -L "$evidence_dir" ]] || {
    echo "capture evidence must be a non-symlink directory" >&2
    exit 1
  }
  evidence_dir=$(readlink -e -- "$evidence_dir")
fi
[[ ! -e "$state_dir" && ! -L "$state_dir" ]] || {
  echo "refusing pre-existing state directory: $state_dir" >&2
  exit 1
}

verify_args=(--plan "$plan" --capture "$capture")
if [[ -n "$evidence_dir" ]]; then
  verify_args+=(--evidence-dir "$evidence_dir")
fi
tools/livepatch/verify.sh "${verify_args[@]}" >/dev/null
row=$(jq -cer --arg rowId "$row_id" '[.rows[] | select(.rowId == $rowId)] | if length == 1 then .[0] else error("row selection is not unique") end' "$plan")
template=$(jq -er '.template' <<<"$row")
case "$template" in
  kernel/livepatch-batch|kernel/livepatch-set|kernel/livepatch-fix) ;;
  *)
    echo "unsupported test template: $template" >&2
    exit 1
    ;;
esac

mkdir -- "$state_dir"
chmod 0700 "$state_dir"
export VPSADMINOS_ENABLE_GENERIC_LIVEPATCH_QUALIFICATION=1
export VPSADMINOS_ONLY_GENERIC_LIVEPATCH_QUALIFICATION=1
export VPSADMINOS_LIVEPATCH_PLAN="$plan"
export VPSADMINOS_LIVEPATCH_CAPTURE="$capture"
export VPSADMINOS_LIVEPATCH_ROW_ID="$row_id"

runner_status=0
set +e
"$bash_path" ./test-runner.sh test --fresh --prebuild --jobs 1 --state-dir "$state_dir" -- "$template@$row_id" \
  2>&1 | tee "$state_dir/test.log"
runner_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$runner_status" >"$state_dir/runner.status"

expected=$(jq -er '.expectedOutcome' <<<"$row")
validator=$(jq -er '.validator // "builtin/test-runner"' <<<"$row")
semantic_log=
if [[ "$validator" != "builtin/test-runner" ]]; then
  state_root=$(readlink -e -- "$state_dir")
  mapfile -d '' result_dirs < <(
    find "$state_root" -mindepth 1 -maxdepth 1 -name 'os-test-*' -print0
  )
  [[ ${#result_dirs[@]} -eq 1 ]] || {
    echo "expected exactly one test result directory" >&2
    exit 1
  }
  result_dir=${result_dirs[0]}
  [[ -d "$result_dir" && ! -L "$result_dir" ]] || {
    echo "test result directory is invalid: $result_dir" >&2
    exit 1
  }

  config_path="$result_dir/config.json"
  [[ -f "$config_path" ]] || {
    echo "test result config is missing: $config_path" >&2
    exit 1
  }
  config_target=$(readlink -e -- "$config_path")
  [[ -f "$config_target" && ! -L "$config_target" ]] || {
    echo "test result config target is not a regular file" >&2
    exit 1
  }
  if [[ -L "$config_path" ]]; then
    [[ "$config_target" == "$state_root/"* || "$config_target" == /nix/store/* ]] || {
      echo "test result config escapes the admitted roots" >&2
      exit 1
    }
  elif [[ "$config_target" != "$state_root/"* ]]; then
    echo "test result config escapes the state directory" >&2
    exit 1
  fi
  expected_name="${template//\//-}-$row_id"
  jq -e \
    --arg name "$expected_name" \
    --arg profileId "$(jq -er '.profileId' <<<"$row")" \
    --arg runnerClass "$(jq -er '.runnerClass' <<<"$row")" \
    --arg setId "$(jq -er '.setId' <<<"$row")" '
      .name == $name
      and .labels == {
        "livepatch-profile": $profileId,
        "livepatch-set": $setId
      }
      and .tags == [$runnerClass]
    ' "$config_target" >/dev/null || {
      echo "test result config identity does not match the selected row" >&2
      exit 1
    }

  test_result="$result_dir/test-result.txt"
  [[ -f "$test_result" && ! -L "$test_result" ]] || {
    echo "test result outcome is missing" >&2
    exit 1
  }
  cmp -s -- "$test_result" <(printf 'expected_success\n') || {
    echo "test result outcome is not expected_success" >&2
    exit 1
  }
  semantic_log="$result_dir/test-runner.log"
  [[ -f "$semantic_log" && ! -L "$semantic_log" ]] || {
    echo "test semantic log is missing" >&2
    exit 1
  }
fi
result_tmp="$state_dir/.result.$$"
[[ ! -e "$result_tmp" && ! -L "$result_tmp" ]]
if [[ "$validator" == "builtin/generic-livepatch-safety-v1" ]]; then
  tools/livepatch/validate-generic-result.sh \
    --plan "$plan" \
    --capture "$capture" \
    --row-id "$row_id" \
    --state-dir "$state_dir" \
    --runner-log "$state_dir/test.log" \
    --semantic-log "$semantic_log" \
    --runner-status "$runner_status" \
    --output "$result_tmp"
elif [[ "$validator" == "builtin/test-runner" ]]; then
  accepted=false
  if [[ "$expected" == "success" && $runner_status -eq 0 ]]; then
    accepted=true
  fi
  jq -n \
    --arg rowId "$row_id" \
    --arg setId "$(jq -er '.setId' <<<"$row")" \
    --arg profileId "$(jq -er '.profileId' <<<"$row")" \
    --argjson runnerStatus "$runner_status" \
    --argjson accepted "$accepted" \
    '{
      schemaVersion: 1,
      rowId: $rowId,
      setId: $setId,
      profileId: $profileId,
      runnerStatus: $runnerStatus,
      accepted: $accepted,
      validator: {id: "builtin/test-runner", status: (if $accepted then "accepted" else "rejected" end)}
    }' >"$result_tmp"
else
  [[ "$validator" == os/livepatches/batches/*/qualification/validators/*.sh && -x "$validator" ]] || {
    echo "oracle validator is outside the allowed tree or not executable: $validator" >&2
    exit 1
  }
  "$validator" \
    --plan "$plan" \
    --capture "$capture" \
    --row-id "$row_id" \
    --state-dir "$state_dir" \
    --runner-log "$state_dir/test.log" \
    --semantic-log "$semantic_log" \
    --runner-status "$runner_status" \
    --output "$result_tmp"
fi

mv -T -- "$result_tmp" "$state_dir/result.json"
tools/livepatch/verify.sh \
  "${verify_args[@]}" \
  --row-id "$row_id" \
  --result "$state_dir/result.json" \
  >"$state_dir/verification.json"
jq -e '.accepted == true' "$state_dir/result.json" >/dev/null

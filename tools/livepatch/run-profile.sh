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
  echo "usage: tools/livepatch/run-profile.sh --plan FILE --capture FILE --row-id ID --state-dir DIR" >&2
  exit 2
}

plan=
capture=
row_id=
state_dir=
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
[[ ! -e "$state_dir" && ! -L "$state_dir" ]] || {
  echo "refusing pre-existing state directory: $state_dir" >&2
  exit 1
}

tools/livepatch/verify.sh --plan "$plan" --capture "$capture" >/dev/null
row=$(jq -cer --arg rowId "$row_id" '[.rows[] | select(.rowId == $rowId)] | if length == 1 then .[0] else error("row selection is not unique") end' "$plan")
adapter=$(jq -er '.testAdapter' <<<"$row")
case "$adapter" in
  kernel/livepatch-batch|kernel/livepatch-set|kernel/livepatch-fix) ;;
  *)
    echo "unsupported test adapter: $adapter" >&2
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
"$bash_path" ./test-runner.sh test --fresh --prebuild --jobs 1 --state-dir "$state_dir" -- "$adapter@$row_id" \
  2>&1 | tee "$state_dir/test.log"
runner_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$runner_status" >"$state_dir/runner.status"

expected=$(jq -er '.expectedOutcome' <<<"$row")
validator=$(jq -er '.validator // "builtin/test-runner"' <<<"$row")
result_tmp="$state_dir/.result.$$"
[[ ! -e "$result_tmp" && ! -L "$result_tmp" ]]
if [[ "$validator" == "builtin/generic-livepatch-safety-v1" ]]; then
  tools/livepatch/validate-generic-result.sh \
    --plan "$plan" \
    --capture "$capture" \
    --row-id "$row_id" \
    --state-dir "$state_dir" \
    --runner-log "$state_dir/test.log" \
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
    --runner-status "$runner_status" \
    --output "$result_tmp"
fi

mv -T -- "$result_tmp" "$state_dir/result.json"
tools/livepatch/verify.sh \
  --plan "$plan" \
  --capture "$capture" \
  --row-id "$row_id" \
  --result "$state_dir/result.json" \
  >"$state_dir/verification.json"
jq -e '.accepted == true' "$state_dir/result.json" >/dev/null

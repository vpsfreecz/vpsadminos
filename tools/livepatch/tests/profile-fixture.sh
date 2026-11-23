# Sourced by the qualification checks; caller supplies work, validator,
# profile_runner and profile_store_config.
profile_root="$work/profile-root"
mkdir -p "$profile_root/tools/livepatch"
ln -s "$validator" "$profile_root/tools/livepatch/validate-generic-result.sh"

printf '#!%s\n' "$BASH" >"$profile_root/tools/livepatch/verify.sh"
cat >>"$profile_root/tools/livepatch/verify.sh" <<'EOF'
set -euo pipefail
printf '{"schemaVersion":1,"verified":true}\n'
EOF
chmod +x "$profile_root/tools/livepatch/verify.sh"

printf '#!%s\n' "$BASH" >"$profile_root/test-runner.sh"
cat >>"$profile_root/test-runner.sh" <<'EOF'
set -euo pipefail

state_dir=
selector=
while (($#)); do
case "$1" in
  --state-dir)
    state_dir=$2
    shift 2
    ;;
  --)
    selector=$2
    break
    ;;
  *) shift ;;
esac
done
[[ -n "$state_dir" && -n "$selector" ]]
template=${selector%@*}
row_id=${selector#*@}
printf '%s\n' "$selector" >"$state_dir/selector.txt"
row=$(jq -cer --arg rowId "$row_id" \
'[.rows[] | select(.rowId == $rowId)] | if length == 1 then .[0] else error("row selection is not unique") end' \
"$VPSADMINOS_LIVEPATCH_PLAN")

if [[ ${FAKE_RUNNER_CASE:-success} == no-result ]]; then
printf '[2026-11-15 13:39:38 +0100] 1 tests successful\n'
exit 0
fi

result_dir="$state_dir/os-test-fixture"
if [[ ${FAKE_RUNNER_CASE:-success} == symlink-result ]]; then
outside="$state_dir/../outside-result-${row_id//[^A-Za-z0-9]/_}"
mkdir "$outside"
ln -s "$outside" "$result_dir"
printf '[2026-11-15 13:39:38 +0100] 1 tests successful\n'
exit 0
fi
mkdir "$result_dir"
if [[ ${FAKE_RUNNER_CASE:-success} == duplicate-result ]]; then
mkdir "$state_dir/os-test-duplicate"
fi

name="${template//\//-}-$row_id"
profile=$(jq -er '.profileId' <<<"$row")
set_id=$(jq -er '.setId' <<<"$row")
runner_class=$(jq -er '.runnerClass' <<<"$row")
case ${FAKE_RUNNER_CASE:-success} in
wrong-name) name=wrong-name ;;
wrong-profile) profile=wrong-profile ;;
wrong-set) set_id=wrong-set ;;
wrong-runner) runner_class=wrong-runner ;;
esac
write_config() {
jq -n \
  --arg name "$name" \
  --arg profile "$profile" \
  --arg runner "$runner_class" \
  --arg setId "$set_id" \
  '{
    name: $name,
    labels: {
      "livepatch-profile": $profile,
      "livepatch-set": $setId
    },
    tags: [$runner]
  }' >"$1"
}
case ${FAKE_RUNNER_CASE:-success} in
regular-config)
  write_config "$result_dir/config.json"
  ;;
config-escape)
  config_target="$state_dir/../outside-config-${row_id//[^A-Za-z0-9]/_}.json"
  write_config "$config_target"
  ln -s "$config_target" "$result_dir/config.json"
  ;;
dangling-config)
  ln -s "$state_dir/missing-config.json" "$result_dir/config.json"
  ;;
missing-config)
  ;;
nonregular-config)
  mkdir "$state_dir/nonregular-config"
  ln -s "$state_dir/nonregular-config" "$result_dir/config.json"
  ;;
wrong-name|wrong-profile|wrong-set|wrong-runner)
  config_dir="$state_dir/prebuild-fixture"
  mkdir "$config_dir"
  write_config "$config_dir/config.json"
  ln -s "$config_dir/config.json" "$result_dir/config.json"
  ;;
*)
  ln -s "$FAKE_STORE_CONFIG" "$result_dir/config.json"
  ;;
esac

if [[ ${FAKE_RUNNER_CASE:-success} == unsuccessful ]]; then
printf 'unexpected_failure\n' >"$result_dir/test-result.txt"
else
printf 'expected_success\n' >"$result_dir/test-result.txt"
fi

if [[ ${FAKE_RUNNER_CASE:-success} != missing-inner ]]; then
: >"$result_dir/test-runner.log"
case ${FAKE_RUNNER_CASE:-success} in
  marker-outer) ;;
  duplicate-marker)
    for _index in 1 2; do
      printf '%s ' "$FAKE_MARKER_PREFIX" >>"$result_dir/test-runner.log"
      cat "$FAKE_MARKER_FILE" >>"$result_dir/test-runner.log"
      printf '\n' >>"$result_dir/test-runner.log"
    done
    ;;
  malformed-marker)
    printf '%s {invalid-json\n' "$FAKE_MARKER_PREFIX" >"$result_dir/test-runner.log"
    ;;
  *)
    printf '%s ' "$FAKE_MARKER_PREFIX" >>"$result_dir/test-runner.log"
    cat "$FAKE_MARKER_FILE" >>"$result_dir/test-runner.log"
    printf '\n' >>"$result_dir/test-runner.log"
    ;;
esac
if [[ ${FAKE_RUNNER_CASE:-success} == inner-fatal ]]; then
  printf 'kernel BUG at synthetic.c:1\n' >>"$result_dir/test-runner.log"
fi
fi

printf '[2026-11-15 13:39:38 +0100] 1 tests successful\n'
if [[ ${FAKE_RUNNER_CASE:-success} == marker-outer ]]; then
printf '%s ' "$FAKE_MARKER_PREFIX"
cat "$FAKE_MARKER_FILE"
printf '\n'
fi
if [[ ${FAKE_RUNNER_CASE:-success} == outer-fatal ]]; then
printf 'kernel BUG at synthetic.c:1\n'
fi
EOF
chmod +x "$profile_root/test-runner.sh"

run_profile_case() {
  local label=$1
  local plan_file=$2
  local capture_file=$3
  local selected_row=$4
  local marker_file=$5
  local marker_prefix=$6
  local runner_case=${7-success}
  local state="$work/profile-$label"

  (
    cd "$profile_root"
    FAKE_RUNNER_CASE="$runner_case" \
      FAKE_MARKER_FILE="$marker_file" \
      FAKE_MARKER_PREFIX="$marker_prefix" \
      FAKE_STORE_CONFIG="$profile_store_config" \
      "$BASH" "$profile_runner" \
        --plan "$plan_file" \
        --capture "$capture_file" \
        --row-id "$selected_row" \
        --state-dir "$state"
  )
}

expect_profile_refuse() {
  local label=$1
  shift
  if run_profile_case "$label" "$@" \
    >"$work/profile-$label.stdout" 2>"$work/profile-$label.stderr"; then
    echo "profile handoff refusal case unexpectedly succeeded: $label" >&2
    exit 1
  fi
  [[ ! -e "$work/profile-$label/result.json" ]]
}

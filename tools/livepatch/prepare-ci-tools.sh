#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

fail() {
  printf 'livepatch CI tools: %s\n' "$*" >&2
  exit 1
}

case ${BASH_SOURCE[0]} in
  */*) script_dir=${BASH_SOURCE[0]%/*} ;;
  *) script_dir=. ;;
esac
inventory=$script_dir/ci-tool-closure.tsv
[[ -f "$inventory" && ! -L "$inventory" ]] || fail "inventory is missing or unsafe: $inventory"

[[ -n ${BASH_VERSION:-} ]] || fail 'Bash is unavailable'
for prerequisite in git nix nix-store; do
  command -v "$prerequisite" >/dev/null || fail "runner prerequisite is unavailable: $prerequisite"
done

declare -A expected_locked=(
  [cat]=coreutils
  [chmod]=coreutils
  [cmp]=diffutils
  [cp]=coreutils
  [cut]=coreutils
  [diff]=diffutils
  [dirname]=coreutils
  [find]=findutils
  [grep]=gnugrep
  [jq]=jq.bin
  [mkdir]=coreutils
  [mktemp]=coreutils
  [mv]=coreutils
  [readlink]=coreutils
  [rm]=coreutils
  [sha256sum]=coreutils
  [sort]=coreutils
  [tee]=coreutils
  [wc]=coreutils
)
declare -A expected_runner=(
  [bash]=bash
  [git]=git
  [nix]=nix
  [nix-store]=nix
)
declare -A seen=()
previous=
locked_count=0
runner_count=0
while IFS=$'\t' read -r scope name class provider extra; do
  [[ -n "$scope" ]] || continue
  [[ ${scope:0:1} == '#' ]] && continue
  [[ -z ${extra:-} && -n "$name" && -n "$class" && -n "$provider" ]] ||
    fail 'inventory row must contain exactly four nonempty fields'
  key=$scope$'\t'$name
  [[ -z "$previous" || "$previous" < "$key" ]] || fail "inventory is unsorted or duplicated at: $key"
  previous=$key
  [[ -z ${seen[$key]+x} ]] || fail "duplicate inventory entry: $key"
  seen[$key]=1
  case "$scope:$class" in
    host:locked)
      [[ ${expected_locked[$name]-} == "$provider" ]] ||
        fail "unexpected locked command/provider: $name/$provider"
      ((locked_count += 1))
      ;;
    host:runner)
      [[ ${expected_runner[$name]-} == "$provider" ]] ||
        fail "unexpected runner command/provider: $name/$provider"
      ((runner_count += 1))
      ;;
    *) fail "invalid inventory scope/class: $scope/$class" ;;
  esac
  [[ "$key$class$provider" != *nfs* && "$key$class$provider" != *amd* &&
    "$key$class$provider" != *intel* && "$key$class$provider" != *6.12* ]] ||
    fail "inventory contains a release, fix, or platform token: $key"
done <"$inventory"

[[ "$locked_count" -eq "${#expected_locked[@]}" ]] || fail 'locked command inventory is incomplete'
[[ "$runner_count" -eq "${#expected_runner[@]}" ]] || fail 'runner command inventory is incomplete'
for name in "${!expected_locked[@]}"; do
  [[ -n ${seen[$'host\t'$name]+x} ]] || fail "locked command is absent from inventory: $name"
done
for name in "${!expected_runner[@]}"; do
  [[ -n ${seen[$'host\t'$name]+x} ]] || fail "runner command is absent from inventory: $name"
done

[[ -n ${GITHUB_PATH:-} ]] || fail 'GITHUB_PATH is not set'
nix_command=${VPSADMINOS_LIVEPATCH_CI_NIX:-nix}
command -v "$nix_command" >/dev/null || fail "Nix command is unavailable: $nix_command"

output=$(
  "$nix_command" build --no-link --print-out-paths 'path:.#livepatch-ci-tools^out'
)
mapfile -t outputs <<<"$output"
[[ ${#outputs[@]} -eq 1 && -n ${outputs[0]} ]] ||
  fail "livepatch-ci-tools returned ${#outputs[@]} outputs"

tool_path=${outputs[0]}/bin
for name in "${!expected_locked[@]}"; do
  [[ -x "$tool_path/$name" ]] || fail "locked command is unavailable: $tool_path/$name"
done

smoke_dir=$("$tool_path/mktemp" -d "${TMPDIR:-/tmp}/livepatch-ci-tools.XXXXXX")
cleanup() {
  "$tool_path/rm" -rf -- "$smoke_dir"
}
trap cleanup EXIT HUP INT TERM
printf 'livepatch-ci-tools\n' >"$smoke_dir/left"
printf 'livepatch-ci-tools\n' >"$smoke_dir/right"
"$tool_path/cmp" -- "$smoke_dir/left" "$smoke_dir/right"
"$tool_path/diff" -- "$smoke_dir/left" "$smoke_dir/right"
"$tool_path/grep" -Fx 'livepatch-ci-tools' "$smoke_dir/left" >/dev/null
[[ $("$tool_path/find" "$smoke_dir" -type f -name left -print) == "$smoke_dir/left" ]] ||
  fail 'find smoke test failed'
hash=$("$tool_path/sha256sum" "$smoke_dir/left")
hash=${hash%% *}
[[ "$hash" =~ ^[0-9a-f]{64}$ ]] || fail 'sha256sum smoke test failed'
"$tool_path/jq" -n -e true >/dev/null
cleanup
trap - EXIT HUP INT TERM

printf '%s\n' "$tool_path" >>"$GITHUB_PATH"

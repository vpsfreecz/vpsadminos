#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

usage() {
  echo "usage: $0 SOURCE_ROOT LIVEPATCH_CI_TOOLS" >&2
  exit 2
}

fail() {
  printf 'ci-tool-closure test: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage
source_root=$1
livepatch_ci_tools=$2
bash_path=${BASH:?}
[[ -d "$source_root" ]] || usage
[[ -d "$livepatch_ci_tools/bin" ]] || usage
[[ -x "$bash_path" ]] || fail "current Bash is not executable: $bash_path"
inventory=$source_root/tools/livepatch/ci-tool-closure.tsv
prepare=$source_root/tools/livepatch/prepare-ci-tools.sh
run_profile=$source_root/tools/livepatch/run-profile.sh
test_runner=$source_root/test-runner.sh
workflow=$source_root/.github/workflows/livepatch.yml
[[ -f "$inventory" && -x "$prepare" && -x "$run_profile" && -x "$test_runner" &&
  -f "$workflow" ]] || usage
"$bash_path" -n "$test_runner"

work=$(mktemp -d "${TMPDIR:-/tmp}/livepatch-ci-tool-test.XXXXXX")
cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT HUP INT TERM

expected=$work/expected.tsv
cat >"$expected" <<'EOF'
# scope	command	class	provider
host	bash	runner	bash
host	cat	locked	coreutils
host	chmod	locked	coreutils
host	cmp	locked	diffutils
host	cp	locked	coreutils
host	cut	locked	coreutils
host	diff	locked	diffutils
host	dirname	locked	coreutils
host	find	locked	findutils
host	git	runner	git
host	grep	locked	gnugrep
host	jq	locked	jq.bin
host	mkdir	locked	coreutils
host	mktemp	locked	coreutils
host	mv	locked	coreutils
host	nix	runner	nix
host	nix-store	runner	nix
host	readlink	locked	coreutils
host	rm	locked	coreutils
host	sha256sum	locked	coreutils
host	sort	locked	coreutils
host	tee	locked	coreutils
host	wc	locked	coreutils
EOF

sort -c "$inventory"
cmp -- "$expected" "$inventory"
[[ $(grep -Fc 'name: Prepare locked livepatch CI tools' "$workflow") -eq 4 ]] ||
  fail 'workflow setup-name count changed'
[[ $(grep -Fc 'run: tools/livepatch/prepare-ci-tools.sh' "$workflow") -eq 4 ]] ||
  fail 'workflow setup-command count changed'
[[ $(grep -Fc '"$bash_path" ./test-runner.sh test --fresh --prebuild --jobs 1' "$run_profile") -eq 1 ]] ||
  fail 'Bash-qualified test-runner invocation count changed'
[[ $(grep -Ec '^[[:space:]]*\./test-runner\.sh[[:space:]]' "$run_profile") -eq 0 ]] ||
  fail 'direct test-runner invocation remains'

fake=$work/fake
mkdir -p "$fake/runner"
while IFS=$'\t' read -r scope name class _provider; do
  [[ "$scope:$class" == host:locked ]] || continue
  [[ -x "$livepatch_ci_tools/bin/$name" ]] ||
    fail "livepatch CI tool output is incomplete: $name"
done <"$inventory"
for name in git nix nix-store; do
  printf '%s\n' "#!$bash_path" 'exit 0' >"$fake/runner/$name"
  chmod 0755 "$fake/runner/$name"
done
printf '%s\n' "#!$bash_path" >"$fake/nix-command"
cat >>"$fake/nix-command" <<'EOF'
set -euo pipefail
[[ $# -eq 4 ]]
[[ $1 == build && $2 == --no-link && $3 == --print-out-paths ]]
[[ $4 == path:.#livepatch-ci-tools^out ]]
printf '%s\n' "$FAKE_NIX_OUTPUT"
EOF
chmod 0755 "$fake/nix-command"

runner_path=$fake/runner
github_path=$work/github-path
env PATH="$runner_path" GITHUB_PATH="$github_path" FAKE_NIX_OUTPUT="$livepatch_ci_tools" \
  VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" "$bash_path" "$prepare"
[[ $(wc -l <"$github_path") -eq 1 ]] || fail 'GITHUB_PATH line count changed'
[[ $(cat "$github_path") == "$livepatch_ci_tools/bin" ]] || fail 'GITHUB_PATH content changed'

expect_refusal() {
  local name=$1
  shift
  if "$@" >"$work/$name.stdout" 2>"$work/$name.stderr"; then
    fail "refusal case accepted: $name"
  fi
}

expect_refusal missing-bash-version env PATH="$livepatch_ci_tools/bin" \
  "$bash_path" -c 'unset BASH_VERSION; source "$1"' _ "$run_profile"
nonexec_bash=$work/nonexec-bash
printf '#!%s\n' "$bash_path" >"$nonexec_bash"
chmod 0644 "$nonexec_bash"
expect_refusal nonexec-bash-path env PATH="$livepatch_ci_tools/bin" \
  "$bash_path" -c 'unset BASH; BASH=$1; source "$2"' _ "$nonexec_bash" "$run_profile"

expect_setup_refusal() {
  local name=$1
  local directory=$2
  expect_refusal "$name" env PATH="$runner_path" GITHUB_PATH="$work/$name.path" \
    FAKE_NIX_OUTPUT="$livepatch_ci_tools" VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" \
    "$bash_path" "$directory/prepare-ci-tools.sh"
}

make_setup_copy() {
  local name=$1
  local directory=$work/$name
  mkdir "$directory"
  cp -- "$prepare" "$directory/prepare-ci-tools.sh"
  chmod 0755 "$directory/prepare-ci-tools.sh"
  printf '%s\n' "$directory"
}

make_private_tools() {
  local name=$1
  local omitted=${2:-}
  local directory=$work/$name
  mkdir -p "$directory/bin"
  while IFS=$'\t' read -r scope tool class _provider; do
    [[ "$scope:$class" == host:locked ]] || continue
    [[ "$tool" != "$omitted" ]] || continue
    ln -s -- "$livepatch_ci_tools/bin/$tool" "$directory/bin/$tool"
  done <"$inventory"
  printf '%s\n' "$directory"
}

missing_dir=$(make_setup_copy manifest-missing)
awk -F '\t' '$1 != "host" || $2 != "cat"' "$inventory" >"$missing_dir/ci-tool-closure.tsv"
expect_setup_refusal manifest-missing "$missing_dir"

duplicate_dir=$(make_setup_copy manifest-duplicate)
awk '1; $0 == "host\tcat\tlocked\tcoreutils" { print }' "$inventory" \
  >"$duplicate_dir/ci-tool-closure.tsv"
expect_setup_refusal manifest-duplicate "$duplicate_dir"

unsorted_dir=$(make_setup_copy manifest-unsorted)
awk 'NR == 2 { first = $0; next } NR == 3 { print; print first; next } { print }' \
  "$inventory" >"$unsorted_dir/ci-tool-closure.tsv"
expect_setup_refusal manifest-unsorted "$unsorted_dir"

provider_dir=$(make_setup_copy manifest-wrong-provider)
awk -F '\t' 'BEGIN { OFS = "\t" } $1 == "host" && $2 == "cat" { $4 = "wrong" } { print }' \
  "$inventory" >"$provider_dir/ci-tool-closure.tsv"
expect_setup_refusal manifest-wrong-provider "$provider_dir"

no_inventory_dir=$(make_setup_copy missing-inventory)
expect_setup_refusal missing-inventory "$no_inventory_dir"

expect_refusal no-github-path env -u GITHUB_PATH PATH="$runner_path" \
  FAKE_NIX_OUTPUT="$livepatch_ci_tools" VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" \
  "$bash_path" "$prepare"
expect_refusal zero-outputs env PATH="$runner_path" GITHUB_PATH="$work/zero-path" \
  FAKE_NIX_OUTPUT= VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" "$bash_path" "$prepare"
expect_refusal multiple-outputs env PATH="$runner_path" GITHUB_PATH="$work/multiple-path" \
  FAKE_NIX_OUTPUT="$livepatch_ci_tools"$'\n'"$livepatch_ci_tools" \
  VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" "$bash_path" "$prepare"

for missing_runner in git nix nix-store; do
  missing_runner_path=$work/missing-$missing_runner-runner
  mkdir "$missing_runner_path"
  for name in git nix nix-store; do
    [[ "$name" != "$missing_runner" ]] || continue
    printf '%s\n' "#!$bash_path" 'exit 0' >"$missing_runner_path/$name"
    chmod 0755 "$missing_runner_path/$name"
  done
  expect_refusal "missing-$missing_runner" env PATH="$missing_runner_path" \
    GITHUB_PATH="$work/missing-$missing_runner.path" FAKE_NIX_OUTPUT="$livepatch_ci_tools" \
    VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" "$bash_path" "$prepare"
done

missing_tool=$(make_private_tools missing-tool cmp)
expect_refusal missing-tool env PATH="$runner_path" GITHUB_PATH="$work/missing-tool.path" \
  FAKE_NIX_OUTPUT="$missing_tool" VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" \
  "$bash_path" "$prepare"

nonexec=$(make_private_tools nonexec jq)
printf '%s\n' "#!$bash_path" 'exit 0' >"$nonexec/bin/jq"
chmod 0644 "$nonexec/bin/jq"
expect_refusal non-executable env PATH="$runner_path" GITHUB_PATH="$work/nonexec.path" \
  FAKE_NIX_OUTPUT="$nonexec" VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" \
  "$bash_path" "$prepare"

failed_smoke=$(make_private_tools failed-smoke jq)
printf '%s\n' "#!$bash_path" 'exit 1' >"$failed_smoke/bin/jq"
chmod 0755 "$failed_smoke/bin/jq"
expect_refusal failed-smoke env PATH="$runner_path" GITHUB_PATH="$work/failed-smoke.path" \
  FAKE_NIX_OUTPUT="$failed_smoke" VPSADMINOS_LIVEPATCH_CI_NIX="$fake/nix-command" \
  "$bash_path" "$prepare"

wrapper=$work/test-runner-wrapper
wrapper_bin=$work/test-runner-bin
record=$work/test-runner-record
mkdir -p "$wrapper" "$wrapper_bin" "$record"
cp -- "$test_runner" "$wrapper/test-runner.sh"
chmod 0755 "$wrapper/test-runner.sh"

printf '%s\n' "#!$bash_path" >"$wrapper_bin/git"
cat >>"$wrapper_bin/git" <<'EOF'
set -euo pipefail
[[ $# -eq 5 ]]
[[ $1 == -C && $2 == "$FAKE_EXPECTED_ROOT" ]]
[[ $3 == rev-parse && $4 == --verify && $5 == HEAD ]]
printf '%s\n' "$FAKE_GIT_REVISION"
EOF
chmod 0755 "$wrapper_bin/git"

printf '%s\n' "#!$bash_path" >"$wrapper_bin/nix"
cat >>"$wrapper_bin/nix" <<'EOF'
set -euo pipefail
[[ $# -eq 4 ]]
[[ $1 == build && $2 == --out-link ]]
[[ $3 == "$FAKE_EXPECTED_ROOT/result/test-runner" ]]
[[ $4 == "$FAKE_EXPECTED_ROOT#test-runner" ]]
mkdir -p "$3/bin"
runner=$3/bin/test-runner
printf '#!%s\n' "$FAKE_BASH_PATH" >"$runner"
cat >>"$runner" <<'RUNNER'
set -euo pipefail
printf '%s\n' "${TEST_RUNNER_REPO_ROOT-}" >"$FAKE_RECORD_DIR/root"
printf '%s\n' "${TEST_RUNNER_REPO_REV-}" >"$FAKE_RECORD_DIR/revision"
printf '%s\n' "$@" >"$FAKE_RECORD_DIR/argv"
exit "$FAKE_CHILD_STATUS"
RUNNER
chmod 0755 "$runner"
EOF
chmod 0755 "$wrapper_bin/nix"

wrapper_path=$wrapper_bin:$livepatch_ci_tools/bin
revision=0123456789abcdef0123456789abcdef01234567
expected_argv=$work/test-runner-expected-argv
printf '%s\n' test --fresh 'two words' >"$expected_argv"
env PATH="$wrapper_path" \
  FAKE_EXPECTED_ROOT="$wrapper" \
  FAKE_GIT_REVISION="$revision" \
  FAKE_BASH_PATH="$bash_path" \
  FAKE_RECORD_DIR="$record" \
  FAKE_CHILD_STATUS=0 \
  "$bash_path" "$wrapper/test-runner.sh" test --fresh 'two words'
[[ $(cat "$record/root") == "$wrapper" ]] || fail 'test-runner root forwarding changed'
[[ $(cat "$record/revision") == "$revision" ]] || fail 'test-runner revision forwarding changed'
cmp -- "$expected_argv" "$record/argv"

runner_status=0
env PATH="$wrapper_path" \
  FAKE_EXPECTED_ROOT="$wrapper" \
  FAKE_GIT_REVISION="$revision" \
  FAKE_BASH_PATH="$bash_path" \
  FAKE_RECORD_DIR="$record" \
  FAKE_CHILD_STATUS=23 \
  "$bash_path" "$wrapper/test-runner.sh" test --failure || runner_status=$?
[[ $runner_status -eq 23 ]] || fail "test-runner child status changed: $runner_status"

printf 'ci-tool-closure: accepted\n'

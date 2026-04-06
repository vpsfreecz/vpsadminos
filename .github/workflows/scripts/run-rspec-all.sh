#!/usr/bin/env bash
set -euo pipefail

workspace="${GITHUB_WORKSPACE:?}"
bundle_path="${workspace}/.gems"

suites=(
  "libosctl:libosctl"
  "converter:converter"
  "osctl:osctl"
  "osctl-exporter:osctl-exporter"
  "osctl-exportfs:osctl-exportfs"
  "osctl-image:osctl-image"
  "osctl-oomd:osctl-oomd"
  "osctl-repo:osctl-repo"
  "osctld:osctld"
  "osup:osup"
  "osvm:osvm"
  "svctl:svctl"
  "test-runner:test-runner"
)

declare -a summaries=()
declare -a failures=()

build_native_extension() {
  local extension_dir="$1"
  local target_path="$2"

  (
    cd "$extension_dir"
    ruby extconf.rb
    make
    cp native.so "$target_path"
  )
}

ensure_libosctl_native() {
  local target_path="${workspace}/libosctl/lib/libosctl/native.so"

  if [ ! -f "$target_path" ]; then
    build_native_extension \
      "${workspace}/libosctl/ext/libosctl" \
      "$target_path"
  fi
}

ensure_osctld_native() {
  local target_path="${workspace}/osctld/lib/osctld/native.so"

  if [ ! -f "$target_path" ]; then
    build_native_extension \
      "${workspace}/osctld/ext/osctld" \
      "$target_path"
  fi
}

run_suite() {
  local name="$1"
  local dir="$2"
  local start_ts
  local end_ts
  local rc=0

  start_ts=$(date +%s)
  echo "::group::${name}"

  (
    set -euo pipefail

    export BUNDLE_GEMFILE="${workspace}/${dir}/Gemfile"
    export BUNDLE_PATH="${bundle_path}"

    cd "${workspace}/${dir}"
    bundle install

    case "$name" in
      libosctl)
        bundle exec rake compile
        ;;
      osctld)
        ensure_libosctl_native
        ensure_osctld_native
        ;;
      converter|osctl|osctl-exporter|osctl-exportfs|osctl-image|osctl-oomd|osctl-repo|osup|osvm|svctl|test-runner)
        ensure_libosctl_native
        ;;
    esac

    bundle exec rspec \
      --format progress \
      --profile 10
  ) || rc=$?

  echo "::endgroup::"
  end_ts=$(date +%s)
  summaries+=("${name}:${rc}:$((end_ts - start_ts))")

  return "$rc"
}

for entry in "${suites[@]}"; do
  IFS=: read -r name dir <<<"$entry"

  if run_suite "$name" "$dir"; then
    continue
  fi

  failures+=("$name")
done

echo "RSpec summary:"

for summary in "${summaries[@]}"; do
  IFS=: read -r name rc duration <<<"$summary"

  if [ "$rc" -eq 0 ]; then
    status="PASS"
  else
    status="FAIL"
  fi

  printf '  %-16s %s (%ss)\n' "$name" "$status" "$duration"
done

if [ "${#failures[@]}" -gt 0 ]; then
  printf 'Failing suites: %s\n' "${failures[*]}"
  exit 1
fi

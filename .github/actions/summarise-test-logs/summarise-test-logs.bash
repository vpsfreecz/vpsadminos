#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

summary_file=${GITHUB_STEP_SUMMARY:?}
logs_root=${LOGS_ROOT:-/tmp/os-test-runner}
tail_lines=${TAIL_LINES:-200}
max_summary_bytes=${MAX_SUMMARY_BYTES:-921600}

case "$tail_lines" in
  '' | *[!0-9]*)
    echo "::error::tail-lines must be a positive integer"
    exit 1
    ;;
esac

case "$max_summary_bytes" in
  '' | *[!0-9]*)
    echo "::error::max-bytes must be a positive integer"
    exit 1
    ;;
esac

if (( tail_lines <= 0 )); then
  echo "::error::tail-lines must be a positive integer"
  exit 1
fi

if (( max_summary_bytes <= 0 )); then
  echo "::error::max-bytes must be a positive integer"
  exit 1
fi

if [ ! -d "$logs_root" ]; then
  echo "No logs directory at $logs_root, skipping summary"
  exit 0
fi

summary_size() {
  if [ -e "$summary_file" ]; then
    wc -c <"$summary_file"
  else
    printf '0\n'
  fi
}

bytes_of() {
  LC_ALL=C printf '%s' "$1" | wc -c
}

remaining_bytes() {
  local reserve=${1:-0}
  local size

  size=$(summary_size)
  printf '%d\n' $((max_summary_bytes - size - reserve))
}

truncated=false
summary_cap_note=$'\n_Log summary truncated to stay under the 1 MiB GitHub step summary limit. Download the full test logs artifact for complete output._\n'
log_cap_note=$'\n[Log excerpt truncated to keep the GitHub step summary under the configured limit.]\n'
details_close=$'</details>\n\n'
code_close=$'```\n\n'

summary_cap_note_bytes=$(bytes_of "$summary_cap_note")
log_cap_note_bytes=$(bytes_of "$log_cap_note")
details_close_bytes=$(bytes_of "$details_close")
code_close_bytes=$(bytes_of "$code_close")

append_text() {
  local text=$1
  local reserve=${2:-0}
  local available
  local text_bytes

  available=$(remaining_bytes "$reserve")
  text_bytes=$(bytes_of "$text")

  if (( text_bytes > available )); then
    truncated=true
    return 1
  fi

  printf '%s' "$text" >>"$summary_file"
}

append_log_file() {
  local log_file=$1
  local tail_tmp
  local tail_bytes
  local available
  local reserve_after_details=$((summary_cap_note_bytes + details_close_bytes))
  local reserve_after_code=$((reserve_after_details + code_close_bytes))
  local reserve_after_truncated_log=$((reserve_after_code + log_cap_note_bytes))

  append_text "#### $(basename "$log_file")"$'\n' "$reserve_after_code" || return 1
  append_text $'```\n' "$reserve_after_code" || return 1

  tail_tmp=$(mktemp)
  tail -n "$tail_lines" "$log_file" >"$tail_tmp"
  tail_bytes=$(wc -c <"$tail_tmp")
  available=$(remaining_bytes "$reserve_after_code")

  if (( tail_bytes <= available )); then
    cat "$tail_tmp" >>"$summary_file"
    rm -f "$tail_tmp"
    append_text "$code_close" "$reserve_after_details" || return 1
    return 0
  fi

  truncated=true
  available=$(remaining_bytes "$reserve_after_truncated_log")

  if (( available > 0 )); then
    head -c "$available" "$tail_tmp" >>"$summary_file"
  fi

  rm -f "$tail_tmp"
  append_text "$log_cap_note" "$reserve_after_code" || true
  append_text "$code_close" "$reserve_after_details" || true
  return 1
}

append_test_logs() {
  local test_dir=$1
  local test_name=$2
  local log_files
  local log_file
  local reserve_after_details=$((summary_cap_note_bytes + details_close_bytes))

  append_text "<details><summary><code>$test_name</code></summary>"$'\n\n' "$reserve_after_details" || return 1

  log_files=("$test_dir"/*.log)

  for log_file in "${log_files[@]}"; do
    if ! append_log_file "$log_file"; then
      append_text "$details_close" "$summary_cap_note_bytes" || true
      return 1
    fi
  done

  append_text "$details_close" "$summary_cap_note_bytes" || true
}

append_text "## Per-test logs (tail, last ${tail_lines} lines each)"$'\n\n' "$summary_cap_note_bytes" || {
  append_text "$summary_cap_note" 0 || true
  exit 0
}

for test_dir in "$logs_root"/os-test-*; do
  test_name=$(basename "$test_dir")
  result_file="$test_dir"/test-result.txt

  [ -e "$result_file" ] || continue

  test_result=$(cat "$result_file")

  if [ "$test_result" = "expected_success" ] || [ "$test_result" = "expected_failure" ]; then
    continue
  fi

  append_test_logs "$test_dir" "$test_name" || break
done

if [ "$truncated" = true ]; then
  append_text "$summary_cap_note" 0 || true
fi

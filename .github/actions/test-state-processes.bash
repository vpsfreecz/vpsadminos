#!/usr/bin/env bash
set -euo pipefail

mode=${1:-}

if [[ "$mode" != prepare && "$mode" != cleanup ]]; then
  echo "::error::test-state-processes.bash requires prepare or cleanup"
  exit 2
fi

for value_name in \
  TEST_STATE_REPOSITORY_ID \
  TEST_STATE_RUN_ID \
  TEST_STATE_RUN_ATTEMPT; do
  value=${!value_name:-}

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "::error::${value_name} must be a numeric GitHub identifier"
    exit 2
  fi
done

state_root=${TEST_STATE_ROOT:-/tmp}

if [[ "$state_root" != /* || "$state_root" == / ]]; then
  echo "::error::TEST_STATE_ROOT must be an absolute directory below /"
  exit 2
fi

state_root=$(readlink -m -- "$state_root")
expected_basename="os-test-runner-${TEST_STATE_REPOSITORY_ID}-${TEST_STATE_RUN_ID}-${TEST_STATE_RUN_ATTEMPT}"
expected_directory="$state_root/$expected_basename"

read_start_time() {
  local pid=$1
  local stat_line stat_fields
  local -a fields

  IFS= read -r stat_line 2>/dev/null <"/proc/$pid/stat" || return 1
  stat_fields=${stat_line##*) }
  [[ "$stat_fields" != "$stat_line" ]] || return 1
  read -r -a fields <<<"$stat_fields"
  (( ${#fields[@]} >= 20 )) || return 1
  [[ "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${fields[19]}"
}

read_effective_uid() {
  local pid=$1
  local key real effective saved filesystem

  while read -r key real effective saved filesystem; do
    if [[ "$key" == Uid: ]]; then
      [[ "$effective" =~ ^[0-9]+$ ]] || return 1
      printf '%s\n' "$effective"
      return 0
    fi
  done 2>/dev/null <"/proc/$pid/status"

  return 1
}

read_github_identity() {
  local pid=$1
  local entry name value

  process_repository_id=
  process_run_id=
  process_run_attempt=
  process_tracking_id=
  repository_count=0
  run_count=0
  attempt_count=0
  tracking_count=0

  while IFS= read -r -d '' entry; do
    name=${entry%%=*}
    value=${entry#*=}

    case "$name" in
      GITHUB_REPOSITORY_ID)
        process_repository_id=$value
        ((repository_count += 1))
        ;;
      GITHUB_RUN_ID)
        process_run_id=$value
        ((run_count += 1))
        ;;
      GITHUB_RUN_ATTEMPT)
        process_run_attempt=$value
        ((attempt_count += 1))
        ;;
      RUNNER_TRACKING_ID)
        process_tracking_id=$value
        ((tracking_count += 1))
        ;;
    esac
  done 2>/dev/null <"/proc/$pid/environ"

  [[ "$repository_count" == 1 && "$run_count" == 1 && \
     "$attempt_count" == 1 && "$tracking_count" == 1 ]] || return 1
  [[ "$process_repository_id" =~ ^[0-9]+$ && \
     "$process_run_id" =~ ^[0-9]+$ && \
     "$process_run_attempt" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$process_tracking_id" ]] || return 1
}

declare -A candidate_repository_ids=()
declare -A candidate_run_ids=()
declare -A candidate_run_attempts=()
reference_seen=false
invalid_reference=false
invalid_current_reference=false

consider_path_reference() {
  local raw_path=$1
  local relative component normalized directory

  [[ "$raw_path" == /* ]] || return 0
  [[ "$raw_path" == "$state_root/"* ]] || return 0

  relative=${raw_path#"$state_root/"}
  component=${relative%%/*}
  [[ "$component" == os-test-runner-* ]] || return 0
  reference_seen=true

  if [[ "$component" == "$expected_basename" ]]; then
    invalid_current_reference=true
  fi

  if [[ ! "$component" =~ ^os-test-runner-([0-9]+)-([0-9]+)-([0-9]+)$ ]]; then
    invalid_reference=true
    return 0
  fi

  normalized=$(readlink -m -- "$raw_path") || {
    invalid_reference=true
    return 0
  }
  directory="$state_root/$component"

  if [[ "$normalized" != "$raw_path" || \
        ( "$normalized" != "$directory" && "$normalized" != "$directory/"* ) ]]; then
    invalid_reference=true
    return 0
  fi

  candidate_repository_ids["$directory"]=${BASH_REMATCH[1]}
  candidate_run_ids["$directory"]=${BASH_REMATCH[2]}
  candidate_run_attempts["$directory"]=${BASH_REMATCH[3]}
}

scan_argv_references() {
  local pid=$1
  local arg part value
  local -a argv parts

  candidate_repository_ids=()
  candidate_run_ids=()
  candidate_run_attempts=()
  reference_seen=false
  invalid_reference=false
  invalid_current_reference=false

  mapfile -d '' -t argv 2>/dev/null <"/proc/$pid/cmdline" || return 1

  for arg in "${argv[@]}"; do
    consider_path_reference "$arg"
    IFS=',' read -r -a parts <<<"$arg"

    for part in "${parts[@]}"; do
      [[ "$part" == *=* ]] || continue
      value=${part#*=}
      consider_path_reference "$value"
    done
  done
}

print_owned_process() {
  local pid=$1 start_time=$2 executable_kind=$3 directory=$4

  printf 'Owned test process: pid=%s start=%s executable=%s repository=%s run=%s attempt=%s state=%s\n' \
    "$pid" \
    "$start_time" \
    "$executable_kind" \
    "${candidate_repository_ids[$directory]}" \
    "${candidate_run_ids[$directory]}" \
    "${candidate_run_attempts[$directory]}" \
    "$directory"
}

print_unowned_conflict() {
  local pid=$1 start_time=$2 executable_kind=$3 directory=$4

  printf 'Unowned test process conflict: pid=%s start=%s executable=%s state=%s\n' \
    "$pid" "$start_time" "$executable_kind" "$directory"
}

blocked=false

for proc_directory in /proc/[0-9]*; do
  pid=${proc_directory##*/}
  IFS= read -r process_name 2>/dev/null <"$proc_directory/comm" || continue

  case "$process_name" in
    qemu-system-x86 | qemu-kvm | virtiofsd)
      ;;
    *)
      continue
      ;;
  esac

  start_time=$(read_start_time "$pid") || continue
  executable=$(readlink -- "/proc/$pid/exe" 2>/dev/null) || continue
  executable_name=${executable##*/}

  case "$executable_name" in
    qemu-system-x86_64 | qemu-kvm)
      executable_kind=qemu
      ;;
    virtiofsd)
      executable_kind=virtiofs
      ;;
    *)
      continue
      ;;
  esac

  scan_argv_references "$pid" || continue
  [[ "$reference_seen" == true ]] || continue

  effective_uid=$(read_effective_uid "$pid") || effective_uid=
  github_identity_valid=true
  read_github_identity "$pid" || github_identity_valid=false

  final_start_time=$(read_start_time "$pid") || continue
  stable_identity=true
  [[ "$final_start_time" == "$start_time" ]] || stable_identity=false

  owned=false
  owned_directory=

  if [[ "$stable_identity" == true && "$effective_uid" == "$EUID" && \
        "$github_identity_valid" == true && "$invalid_reference" == false && \
        "${#candidate_repository_ids[@]}" == 1 ]]; then
    for directory in "${!candidate_repository_ids[@]}"; do
      if [[ "${candidate_repository_ids[$directory]}" == "$process_repository_id" && \
            "${candidate_run_ids[$directory]}" == "$process_run_id" && \
            "${candidate_run_attempts[$directory]}" == "$process_run_attempt" ]]; then
        owned=true
        owned_directory=$directory
      fi
    done
  fi

  if [[ "$mode" == prepare ]]; then
    if [[ "$owned" == true && \
          "${candidate_repository_ids[$owned_directory]}" == "$TEST_STATE_REPOSITORY_ID" ]]; then
      print_owned_process "$pid" "$start_time" "$executable_kind" "$owned_directory"
      blocked=true
    elif [[ "$owned" == false ]]; then
      conflict_directory='<ambiguous>'
      if [[ "${#candidate_repository_ids[@]}" == 1 ]]; then
        for directory in "${!candidate_repository_ids[@]}"; do
          conflict_directory=$directory
        done
      elif [[ "${#candidate_repository_ids[@]}" == 0 ]]; then
        conflict_directory='<unresolved>'
      fi
      print_unowned_conflict "$pid" "$start_time" "$executable_kind" "$conflict_directory"
      blocked=true
    fi
  elif [[ "$owned" == true && "$owned_directory" == "$expected_directory" ]]; then
    print_owned_process "$pid" "$start_time" "$executable_kind" "$owned_directory"
    blocked=true
  elif [[ "$owned" == false && \
          ( -v 'candidate_repository_ids[$expected_directory]' || \
            "$invalid_current_reference" == true ) ]]; then
    print_unowned_conflict "$pid" "$start_time" "$executable_kind" "$expected_directory"
    blocked=true
  fi
done

if [[ "$blocked" == true ]]; then
  exit 1
fi

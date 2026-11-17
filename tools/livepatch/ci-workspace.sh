#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

usage() {
  cat >&2 <<'EOF'
usage: ci-workspace.sh prepare --root DIR --job KIND --run-id N --run-attempt N
       ci-workspace.sh cleanup --root DIR --job KIND --run-id N --run-attempt N --directory DIR
EOF
  exit 2
}

fail() {
  printf 'livepatch CI workspace: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
operation=$1
shift

case "$operation" in
  prepare)
    [[ $# -eq 8 && $1 == --root && $3 == --job && $5 == --run-id &&
      $7 == --run-attempt ]] || usage
    root_arg=$2
    job=$4
    run_id=$6
    run_attempt=$8
    directory_arg=
    ;;
  cleanup)
    [[ $# -eq 10 && $1 == --root && $3 == --job && $5 == --run-id &&
      $7 == --run-attempt && $9 == --directory ]] || usage
    root_arg=$2
    job=$4
    run_id=$6
    run_attempt=$8
    directory_arg=${10}
    ;;
  *) usage ;;
esac

case "$job" in
  discover | capture | qualify | results) ;;
  *) fail "unsupported job kind: $job" ;;
esac
[[ $run_id =~ ^[0-9]+$ ]] || fail 'run id must be numeric'
[[ $run_attempt =~ ^[0-9]+$ ]] || fail 'run attempt must be numeric'
[[ $root_arg == /* && $root_arg != / && -d $root_arg && ! -L $root_arg ]] ||
  fail 'root must be an existing absolute non-symlink directory below /'
root=$(readlink -e -- "$root_arg")
[[ $root != / ]] || fail 'root must be below /'

admit_directory_name() {
  local directory=$1
  local name=${directory##*/}
  local prefix="livepatch-$job-$run_id-$run_attempt."
  local suffix

  [[ ${directory%/*} == "$root" && $name == "$prefix"* ]] || return 1
  suffix=${name#"$prefix"}
  [[ ${#suffix} -eq 6 && $suffix =~ ^[A-Za-z0-9]{6}$ ]]
}

if [[ $operation == prepare ]]; then
  umask 077
  directory=$(mktemp -d "$root/livepatch-$job-$run_id-$run_attempt.XXXXXX")
  canonical=$(readlink -e -- "$directory")
  [[ $directory == "$canonical" && -d $directory && ! -L $directory && -O $directory ]] ||
    fail 'prepared directory is not an owned canonical directory'
  admit_directory_name "$directory" || fail 'prepared directory has an invalid identity'
  printf '%s\n' "$directory"
  exit 0
fi

[[ $directory_arg == /* ]] || fail 'cleanup directory must be absolute'
directory=$(readlink -m -- "$directory_arg")
[[ $directory == "$directory_arg" ]] || fail 'cleanup directory must be normalized'
admit_directory_name "$directory" || fail 'cleanup directory has an invalid identity'

if [[ ! -e $directory && ! -L $directory ]]; then
  exit 0
fi
[[ -d $directory && ! -L $directory && -O $directory ]] ||
  fail 'cleanup directory is not an owned non-symlink directory'
[[ $(readlink -e -- "$directory") == "$directory" ]] ||
  fail 'cleanup directory is not canonical'

find -P "$directory" -type d -exec chmod u+rwx -- {} +
rm -rf -- "$directory"
[[ ! -e $directory && ! -L $directory ]] || fail 'cleanup directory still exists'

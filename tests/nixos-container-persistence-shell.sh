#!/usr/bin/env bash
# Layout-specific doubles run generated callbacks. The allocator marker proves
# shell control flow only; registered VM tests use the real account allocator.
set -euo pipefail
snippet=$1
early_mounts=$2
mode=$3
selected_options=$4
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT
fixture_bind_state=true
exact=false
configured_target=/var/lib/nixos
case "$mode" in
  declared|undeclared|filesystem) exact=true ;;
  var) configured_target=/var ;;
  var-lib) configured_target=/var/lib ;;
  nonbind) fixture_bind_state=false; configured_target=/var/log ;;
esac
case "$mode" in
  nonbind) required_options=(defaults mode=0755) ;;
  rbind) required_options=(rbind x-gvfs-hide) ;;
  *) required_options=(bind x-gvfs-hide) ;;
esac
for option in "${required_options[@]}"; do
  [[ ",$selected_options," == *",$option,"* ]]
done
scenarios=(fresh existing_metadata matching_live failed_bind failed_remount failed_mount_lookup wrong_result failed_mkdir failed_chown failed_chmod dangling_target)
if "$fixture_bind_state"; then scenarios+=(missing_parents wrong_live source_file parent_file failed_lookup dangling_source); fi
case "$mode" in
  declared|filesystem|transitive) scenarios+=(missing_backing failed_required_remount) ;;
  undeclared) scenarios+=(root_backing absent_undeclared) ;;
esac
case "$mode" in declared|transitive) scenarios+=(matching_backing wrong_backing missing_backing_source) ;; esac
if [ "$mode" = transitive ]; then scenarios+=(missing_transitive); fi
if [ "$mode" = explicit ]; then scenarios+=(missing_dependency failed_unrelated); fi
for fixture_scenario in "${scenarios[@]}"; do
  fixture_case_root="$fixture_root/$fixture_scenario"
  fixture_backing="$fixture_case_root/backing storage"
  fixture_host="$fixture_case_root/host storage"
  fixture_bridge="$fixture_case_root/bridge"
  fixture_dependency="$fixture_case_root/dependency"
  fixture_target="$fixture_case_root/state_target"
  fixture_log_target="$fixture_case_root/log_target"
  mkdir -p "$fixture_host/bridge"
  case "$mode" in declared|transitive) ln -s "$fixture_host" "$fixture_backing" ;; *) mkdir "$fixture_backing" ;; esac
  if [ "$mode" = transitive ]; then ln -s "$fixture_backing/bridge" "$fixture_bridge"; fixture_source="$fixture_bridge/state"
  elif "$fixture_bind_state"; then fixture_source="$fixture_backing/nixos"
  else fixture_source="$fixture_case_root/device-file"; touch "$fixture_source"
  fi
  log_source="$fixture_backing/log"
  before_metadata=
  case "$fixture_scenario" in
    missing_parents) fixture_source="$(dirname "$fixture_source")/new-parent/state" ;;
    existing_metadata)
      if "$fixture_bind_state"; then metadata_path="$fixture_source"; else metadata_path="$fixture_target"; fi
      mkdir "$metadata_path"; chmod 0710 "$metadata_path"
      printf 'existing data\n' > "$metadata_path/payload"
      before_metadata=$(stat -c '%u:%g:%a:%i' "$metadata_path") ;;
    matching_live|failed_remount)
      if "$fixture_bind_state"; then mkdir "$fixture_source"; ln -s "$fixture_source" "$fixture_target"; else mkdir "$fixture_target"; fi
      printf 'matching data\n' > "$fixture_target/payload"
      touch "$fixture_case_root/mounted-state" ;;
    wrong_live)
      mkdir "$fixture_case_root/wrong"; ln -s "$fixture_case_root/wrong" "$fixture_target"; touch "$fixture_case_root/mounted-state" ;;
    source_file) touch "$fixture_source" ;;
    dangling_source) ln -s "$fixture_case_root/absent" "$fixture_source" ;;
    dangling_target) ln -s "$fixture_case_root/absent" "$fixture_target" ;;
    wrong_backing)
      mkdir "$fixture_case_root/wrong backing"; rm "$fixture_backing"; ln -s "$fixture_case_root/wrong backing" "$fixture_backing" ;;
    missing_backing_source) rmdir "$fixture_host/bridge" "$fixture_host" ;;
    missing_transitive) rmdir "$fixture_host/bridge" ;;
    parent_file)
      if [ "$mode" = transitive ]; then rm "$fixture_bridge"; touch "$fixture_bridge"
      elif [ -L "$fixture_backing" ]; then rm "$fixture_backing"; touch "$fixture_backing"
      else rmdir "$fixture_backing"; touch "$fixture_backing"
      fi ;;
    failed_mount_lookup) mkdir "$fixture_target" ;;
  esac
  rewrite() {
    sed -e "s|/fixture/backing storage/nixos|$fixture_source|g" \
      -e "s|/fixture/bridge/state|$fixture_source|g" \
      -e "s|/fixture/backing storage|$fixture_backing|g" \
      -e "s|/fixture/host storage|$fixture_host|g" \
      -e "s|/fixture/bridge|$fixture_bridge|g" \
      -e "s|/fixture/dependency|$fixture_dependency|g" \
      -e "s|/fixture/device-file|$fixture_source|g" \
      -e "s|/fixture/unrelated|$fixture_case_root/unrelated|g" \
      -e "s|\"$configured_target\"|\"$fixture_target\"|g" \
      -e "s|'$configured_target'|'$fixture_target'|g" \
      -e "s|= $configured_target ]|= '$fixture_target' ]|g" \
      -e "s|\"/var/log\"|\"$fixture_log_target\"|g" \
      -e "s|'/var/log'|'$fixture_log_target'|g" \
      -e "s|= /var/log ]|= '$fixture_log_target' ]|g" "$1"
  }
  expected_selected_options=$(rewrite <(printf '%s\n' "$selected_options"))
  # Filter fixture calls; host /proc,/sys,/run paths are never touched.
  awk '/^specialMount "\/fixture\// || /^specialMount "fixture-/ || /^specialMount .* "\/fixture\// { print }' "$early_mounts" > "$fixture_case_root/selected.sh"
  expected_calls=$(wc -l < "$fixture_case_root/selected.sh")
  rewrite "$fixture_case_root/selected.sh" > "$fixture_case_root/mounts.sh"
  rewrite "$snippet" | sed -E "s|^[[:space:]]*source .*|source '$fixture_case_root/mounts.sh'|" > "$fixture_case_root/activation.sh"
  bash -n "$fixture_case_root/activation.sh"
  bash -n "$fixture_case_root/mounts.sh"
  set +e
  (
    set +e
    umask 0077
    _status=0
    trap '_status=1' ERR
    mountpoint() {
      local path="${*: -1}"
      if [ "$path" = / ]; then return 0; fi
      case "$path" in
        "$fixture_backing") [ "$fixture_scenario" != missing_backing ] || return 32; return 0 ;;
        "$fixture_bridge") return 0 ;;
        "$fixture_dependency") [ "$fixture_scenario" != missing_dependency ] || return 32; return 0 ;;
      esac
      [ "$fixture_scenario" != failed_mount_lookup ] || return 1
      if [ "$path" = "$fixture_target" ]; then test -f "$fixture_case_root/mounted-state" || return 32
      elif [ "$path" = "$fixture_log_target" ]; then test -f "$fixture_case_root/mounted-log" || return 32
      else return 32
      fi
    }
    dirname() { [ "$fixture_scenario" != failed_lookup ] || return 1; command dirname "$@"; }
    mkdir() {
      [ "$fixture_scenario" != failed_mkdir ] || return 1
      if ! "$fixture_bind_state" && [[ "$*" == *"$fixture_source"* ]]; then return 1; fi
      command mkdir "$@" || return 1
      if [ "$#" = 4 ] && [ "$1" = -m ] && [ "$2" = 0755 ] && [ "$3" = -- ]; then
        printf '%s\n' "$4" >> "$fixture_case_root/created-directories"
      fi
    }
    # A non-root pure sandbox cannot chown to root. Check the numeric request
    # and fresh-only path; the registered guest tests verify actual ownership.
    chown() {
      [ "$#" = 3 ] && [ "$1" = 0:0 ] && [ "$2" = -- ] || return 1
      grep -Fxq -- "$3" "$fixture_case_root/created-directories" || return 1
      printf '%s\n' "$3" >> "$fixture_case_root/chown-calls"
      [ "$fixture_scenario" != failed_chown ]
    }
    chmod() {
      if [ "$#" = 3 ] && [ "$1" = 00755 ] && [ "$2" = -- ]; then
        grep -Fxq -- "$3" "$fixture_case_root/created-directories" || return 1
        printf '%s\n' "$3" >> "$fixture_case_root/chmod-calls"
        [ "$fixture_scenario" != failed_chmod ] || return 1
      fi
      command chmod "$@"
    }
    mount() {
      printf '%s\n' "$*" >> "$fixture_case_root/mount-calls"
      local from="${*: -2:1}" to="${*: -1}" options="$4"
      if [ "$to" = "$fixture_target" ]; then printf '%s\n' "$options" >> "$fixture_case_root/target-options"; fi
      if [ "$to" = "$fixture_backing" ]; then
        [ "$fixture_scenario" != missing_backing ] && [ "$fixture_scenario" != failed_required_remount ]; return
      fi
      if [ "$to" = "$fixture_bridge" ]; then return 0; fi
      if [ "$to" = "$fixture_dependency" ]; then [ "$fixture_scenario" != missing_dependency ]; return; fi
      if [ "$to" = "$fixture_case_root/unrelated" ]; then [ "$fixture_scenario" != failed_unrelated ]; return; fi
      [ "$fixture_scenario" != failed_bind ] && [ "$fixture_scenario" != failed_remount ] || return 1
      if [[ "$options" != remount,* ]]; then
        if "$fixture_bind_state"; then
          rmdir "$to" || return 1
          if [ "$fixture_scenario" = wrong_result ]; then ln -s "$fixture_backing" "$to" || return 1
          else ln -s "$from" "$to" || return 1
          fi
        elif [ "$fixture_scenario" = wrong_result ]; then return 0
        fi
        if [ "$to" = "$fixture_target" ]; then touch "$fixture_case_root/mounted-state"; else touch "$fixture_case_root/mounted-log"; fi
      fi
    }
    . "$fixture_case_root/activation.sh"
    touch "$fixture_case_root/allocator-reached"
  ) > "$fixture_case_root/output" 2>&1
  status=$?
  set -e
  case "$fixture_scenario" in
    fresh|missing_parents|existing_metadata|matching_live|matching_backing|root_backing|absent_undeclared|failed_unrelated)
      [ "$status" = 0 ] && [ -f "$fixture_case_root/allocator-reached" ] || { cat "$fixture_case_root/output"; exit 1; }
      if "$fixture_bind_state"; then [ "$fixture_source" -ef "$fixture_target" ]; else [ -f "$fixture_source" ]; fi
      if "$exact"; then [ "$log_source" -ef "$fixture_log_target" ]; fi
      [ "$(wc -l < "$fixture_case_root/mount-calls")" = "$expected_calls" ]
      if [ -f "$fixture_case_root/created-directories" ]; then
        cmp "$fixture_case_root/created-directories" "$fixture_case_root/chown-calls"
        cmp "$fixture_case_root/created-directories" "$fixture_case_root/chmod-calls"
      else
        [ ! -e "$fixture_case_root/chown-calls" ] && [ ! -e "$fixture_case_root/chmod-calls" ]
      fi
      if [ "$fixture_scenario" = matching_live ]; then
        [ "$(cat "$fixture_case_root/target-options")" = "remount,$expected_selected_options" ]
        [ "$(grep -Fc -- " $fixture_target" "$fixture_case_root/mount-calls")" = 1 ]
        [ "$(cat "$fixture_target/payload")" = 'matching data' ]
      fi ;;
    *) [ "$status" != 0 ] && [ ! -f "$fixture_case_root/allocator-reached" ] || { cat "$fixture_case_root/output"; exit 1; } ;;
  esac
  if [ "$fixture_scenario" = existing_metadata ]; then
    [ "$before_metadata" = "$(stat -c '%u:%g:%a:%i' "$metadata_path")" ]
    [ "$(cat "$metadata_path/payload")" = 'existing data' ]
  fi
  if [ "$fixture_scenario" = fresh ]; then
    if "$fixture_bind_state"; then [ "$(stat -c '%a' "$fixture_source")" = 755 ]; fi
    [ "$(stat -Lc '%a' "$fixture_target")" = 755 ]
  fi
  if [ "$fixture_scenario" = missing_parents ]; then
    [ "$(stat -c '%a' "$fixture_source")" = 755 ]
    [ "$(stat -c '%a' "$(dirname "$fixture_source")")" = 755 ]
  fi
  case "$fixture_scenario" in
    wrong_backing|missing_backing|failed_required_remount|missing_dependency) [ ! -e "$fixture_source" ]; [ ! -e "$fixture_host/nixos" ] ;;
    missing_backing_source) [ ! -e "$fixture_host" ] ;;
    missing_transitive) [ ! -e "$fixture_host/bridge" ] ;;
    wrong_live) [ ! -e "$fixture_source" ]; [ "$fixture_target" -ef "$fixture_case_root/wrong" ] ;;
    failed_remount) [ -f "$fixture_case_root/mounted-state" ]; [ "$(cat "$fixture_target/payload")" = 'matching data' ] ;;
    failed_chown) [ -s "$fixture_case_root/chown-calls" ]; [ ! -e "$fixture_case_root/chmod-calls" ] ;;
    failed_chmod) [ -s "$fixture_case_root/chown-calls" ]; [ -s "$fixture_case_root/chmod-calls" ] ;;
  esac
  printf 'PASS %s %s\n' "$mode" "$fixture_scenario"
done

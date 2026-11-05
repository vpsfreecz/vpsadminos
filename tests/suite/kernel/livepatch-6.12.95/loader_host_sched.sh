#!/usr/bin/env bash
# Temporary, read-only evidence for the one diagnostic qualification job.
# The wrapper owns our lifetime; never discover a QEMU by process name.
loader_proc=/proc
loader_qemu=/nix/store/kanckc6ljipqzjsrvj4aqaf87a4rhswr-qemu-host-cpu-only-for-vm-tests-10.2.4/bin/qemu-system-x86_64

loader_stat() {
  local line rest
  IFS= read -r -n 4097 line < "$1/stat" || return 1
  ((${#line} <= 4096)) || return 1
  [[ $line == "$2 ("* && $line == *') '* ]] || return 1
  rest=${line##*) }
  s_comm=${line#*' ('}; s_comm=${s_comm%") $rest"}
  read -r -a s_fields <<< "$rest"
  ((${#s_fields[@]} >= 37)) || return 1
  [[ ${s_fields[0]} =~ ^[RSDZTtXxKWPI]$ ]] || return 1
  local i
  for i in 1 11 12 17 19 36; do
    [[ ${s_fields[$i]} =~ ^[0-9]{1,18}$ ]] || return 1
  done
  s_parent=${s_fields[1]}; s_start=${s_fields[19]}
}

loader_identity() {
  loader_stat "$1" "$2" && [[ $s_start == "$3" && ${s_fields[0]} != Z ]] || return 1
  [[ $(readlink -e "$1/exe") == "$4" ]] || return 1
}

loader_ancestry() {
  local pid=$1 start=$2 depth=0 parent
  while ((depth++ < 64)); do
    loader_stat "$loader_proc/$pid" "$pid" && [[ $s_start == "$start" ]] || return 1
    if [[ $pid == "$loader_child" ]]; then
      [[ $start == "$loader_child_start" ]] && return 0
      return 1
    fi
    parent=$s_parent
    [[ $parent =~ ^[1-9][0-9]*$ && $parent != 1 ]] || return 1
    loader_stat "$loader_proc/$parent" "$parent" || return 1
    pid=$parent; start=$s_start
  done
  return 1
}

loader_emit() {
  local text=$1
  # Reserve 32 KiB of the 64 MiB budget for bounded handshake/status metadata.
  if ((loader_bytes + ${#text} + 1 > 67076096)); then
    loader_failure='INCOMPLETE: 64MiB output cap reached'; return 1
  fi
  printf '%s\n' "$text" >> "$loader_output" || return 1
  loader_bytes=$((loader_bytes + ${#text} + 1))
}

# Values in this function have named, separate clock domains. Only uptime
# differences within the inherited runner proc view enforce the elapsed cap.
loader_clock_values() {
  local raw_up=$1 raw_wall=$2 seconds fraction
  loader_failure='INCOMPLETE: invalid runner-proc-uptime observation'
  [[ $raw_up =~ ^([0-9]{1,10})\.([0-9]{2})$ ]] || return 1
  loader_up_cs=$((10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]}))
  loader_up=$raw_up
  loader_failure='INCOMPLETE: invalid runner-EPOCHREALTIME observation'
  [[ $raw_wall =~ ^([0-9]{1,10})\.([0-9]{1,6})$ ]] || return 1
  seconds=${BASH_REMATCH[1]}; fraction=${BASH_REMATCH[2]}000000; fraction=${fraction:0:6}
  loader_wall_us=$((10#$seconds * 1000000 + 10#$fraction)); loader_wall=$raw_wall
  loader_failure='INCOMPLETE: runner-proc-uptime regressed'
  ((loader_up_cs >= loader_origin_cs && loader_up_cs >= ${loader_last_up_cs:-loader_origin_cs})) || return 1
  loader_failure='INCOMPLETE: runner-EPOCHREALTIME regressed'
  ((loader_wall_us >= ${loader_last_wall_us:-0})) || return 1
  loader_failure='INCOMPLETE: 3600s cap from wrapper origin reached'
  ((loader_up_cs - loader_origin_cs < 360000)) || return 1
  loader_last_up_cs=$loader_up_cs; loader_last_wall_us=$loader_wall_us
  loader_failure='INCOMPLETE: required baseline observation unavailable'
}

loader_read_clock() {
  local up idle extra
  loader_failure='INCOMPLETE: runner-proc-uptime unavailable'
  IFS=' ' read -r -n 128 up idle extra < "$loader_proc/uptime" || return 1
  [[ -z $extra ]] || return 1
  loader_clock_values "$up" "${EPOCHREALTIME-}"
}

# Status is supplemental, never printed wholesale. Read one overflow byte to
# detect the 16-KiB bound, preserving trailing newlines with a sentinel.
loader_switches() {
  local text line voluntary=0 involuntary=0 bad=false
  loader_voluntary=UNAVAILABLE; loader_involuntary=UNAVAILABLE
  loader_switch_reason=unreadable
  if ! text=$(head -c 16385 "$1/status" 2>/dev/null && printf '.'); then return 0; fi
  text=${text%.}
  if ((${#text} > 16384)); then loader_switch_reason=oversized; return 0; fi
  while IFS= read -r line; do
    case $line in
      voluntary_ctxt_switches:*)
        ((voluntary+=1))
        if [[ $line =~ ^voluntary_ctxt_switches:[[:space:]]+([0-9]{1,18})[[:space:]]*$ ]]; then
          loader_voluntary=${BASH_REMATCH[1]}
        else bad=true; fi;;
      nonvoluntary_ctxt_switches:*)
        ((involuntary+=1))
        if [[ $line =~ ^nonvoluntary_ctxt_switches:[[:space:]]+([0-9]{1,18})[[:space:]]*$ ]]; then
          loader_involuntary=${BASH_REMATCH[1]}
        else bad=true; fi;;
    esac
  done <<< "$text"
  loader_switch_reason=available
  if ((voluntary > 1 || involuntary > 1)); then loader_switch_reason=duplicate
  elif $bad; then loader_switch_reason=malformed
  elif ((voluntary != 1 || involuntary != 1)); then loader_switch_reason=missing
  fi
  if [[ $loader_switch_reason != available ]]; then
    loader_voluntary=UNAVAILABLE; loader_involuntary=UNAVAILABLE
  fi
}

loader_snapshot_identity() {
  loader_identity "$loader_qdir" "$loader_pid" "$loader_start" "$loader_qemu" || return 1
  if ((${s_fields[17]} < 128 || ${s_fields[17]} > 256)); then
    loader_failure='INCOMPLETE: required 128..256 total-thread bound'; return 1
  fi
  loader_ancestry "$loader_pid" "$loader_start" || return 1
  loader_identity "$loader_child_dir" "$loader_child" "$loader_child_start" "$loader_child_exe" && [[ $s_parent == "$loader_job" ]]
}

loader_discover_vcpus() {
  local dir tid index
  local -a tids=("$loader_qdir"/task/[0-9]*)
  local -A seen=()
  if ((${#tids[@]} > 256)); then loader_failure='INCOMPLETE: 256-thread discovery cap reached'; return 1; fi
  for dir in "${tids[@]}"; do
    tid=${dir##*/}
    loader_stat "$dir" "$tid" || return 1
    if [[ $s_comm =~ ^CPU\ ([0-9]+)/KVM$ ]]; then
      index=${BASH_REMATCH[1]}
      if ((index >= 128)) || [[ ${seen[$index]+yes} ]]; then return 1; fi
      seen[$index]="vcpu $index $tid $s_start"
    fi
  done
  ((${#seen[@]} == 128)) || return 1
  loader_expected_map=''
  for ((index=0;index<128;index++)); do loader_expected_map+="${seen[$index]}"$'\n'; done
}

loader_required_vcpu() {
  loader_stat "$1" "$2" && [[ $s_start == "$3" && $s_comm == "CPU $4/KVM" && ${s_fields[0]} != Z ]]
}

loader_snapshot() {
  local begin_wall begin_up word tid start fd dir index key progress previous_user previous_sys
  loader_failure='INCOMPLETE: required proc identity, ancestry or baseline data unavailable'
  loader_read_clock || return 1
  if [[ -n ${loader_previous_sample_cs:-} ]]; then
    loader_failure='INCOMPLETE: runner-proc-uptime stalled across sample interval'
    ((loader_up_cs > loader_previous_sample_cs)) || return 1
    loader_failure='INCOMPLETE: runner-EPOCHREALTIME stalled across sample interval'
    ((loader_wall_us > loader_previous_sample_wall_us)) || return 1
  fi
  begin_wall=$loader_wall; begin_up=$loader_up
  loader_failure='INCOMPLETE: required proc identity, ancestry or baseline data unavailable'
  loader_snapshot_identity || return 1
  if [[ -z ${loader_expected_map:-} ]]; then loader_discover_vcpus || return 1; fi
  loader_emit "sample begin wall=$begin_wall uptime=$begin_up gap_begin=${loader_previous_end:-none} gap_end=$begin_up uptime_view=runner-proc-uptime wall_view=runner-EPOCHREALTIME" || return 1
  # Discovery is never repeated. Incidental task lifetimes are outside this
  # required-vCPU scope, not silently missing process-wide observations.
  loader_map=$loader_expected_map
  while read -r word index tid start; do
    [[ -n $word ]] || continue
    dir="$loader_qdir/task/$tid"
    exec {fd}< "$dir" || return 1
    dir="/proc/$BASHPID/fd/$fd"
    if ! loader_required_vcpu "$dir" "$tid" "$start" "$index"; then exec {fd}<&-; return 1; fi
    local state=${s_fields[0]} cpu=${s_fields[36]} user=${s_fields[11]} sys=${s_fields[12]}
    loader_switches "$dir"
    if ! loader_required_vcpu "$dir" "$tid" "$start" "$index"; then exec {fd}<&-; return 1; fi
    exec {fd}<&-
    key="$tid:$start"; progress=first_sample
    if [[ ${loader_previous_cpu[$key]+yes} ]]; then
      read -r previous_user previous_sys <<< "${loader_previous_cpu[$key]}"
      progress=same_identity_interval
      if ((10#$user < 10#$previous_user || 10#$sys < 10#$previous_sys)); then progress=UNAVAILABLE_counter_decreased; fi
    fi
    loader_previous_cpu[$key]="$user $sys"
    loader_emit "tid=$tid start=$start label=vcpu$index state=$state cpu=$cpu user=$user sys=$sys cpu_interval=$progress voluntary_ctxt_switches=$loader_voluntary nonvoluntary_ctxt_switches=$loader_involuntary switches=$loader_switch_reason runtime=UNAVAILABLE wait=UNAVAILABLE slices=UNAVAILABLE" || return 1
  done <<< "$loader_expected_map"
  while read -r word index tid start; do
    [[ -n $word ]] || continue
    loader_required_vcpu "$loader_qdir/task/$tid" "$tid" "$start" "$index" || return 1
  done <<< "$loader_expected_map"
  loader_snapshot_identity || return 1
  loader_read_clock || return 1
  loader_emit "sample end wall=$loader_wall uptime=$loader_up uptime_view=runner-proc-uptime wall_view=runner-EPOCHREALTIME" || return 1
  loader_previous_end=$loader_up
  loader_previous_sample_cs=$loader_up_cs; loader_previous_sample_wall_us=$loader_wall_us
}

loader_launch() {
  local log=$1 line key value active=false count=0
  [[ -f $log && ! -L $log && $(wc -c < "$log") -le 65536 ]] || return 1
  local -A fields=()
  while IFS= read -r line; do
    if [[ $line == 'ACTION: qemu-launch' ]]; then active=true; ((count+=1)); continue; fi
    [[ $line == '---' ]] && active=false
    if $active && [[ $line == *': '* ]]; then
      key=${line%%:*}; value=${line#*: }
      [[ ! ${fields[$key]+yes} ]] || return 1
      fields[$key]=$value
    fi
  done < "$log"
  ((count == 1)) || return 1
  [[ ${fields[PID]:-} =~ ^[1-9][0-9]*$ && ${fields[START_TIME_TICKS]:-} =~ ^[0-9]+$ ]] || return 1
  [[ ${fields[CPUS]:-} == 128 && ${fields[CORES]:-} == 128 && ${fields[THREADS]:-} == 1 &&
     ${fields[SOCKETS]:-} == 1 && ${fields[MEMORY_MIB]:-} == 16384 && ${fields[BOOT_MODE]:-} == direct ]] || return 1
  [[ ${fields[QEMU]:-} == "${loader_qemu%/*}/qemu-kvm" ]] || return 1
  loader_pid=${fields[PID]}; loader_start=${fields[START_TIME_TICKS]}
  loader_emit "launch pid=$loader_pid start=$loader_start exe=$loader_qemu topology=128/128/1/1 memory=16384 expected_naming=debug-threads=on log=${log##*/}" || return 1
}

loader_main() {
  set -u
  umask 077
  export LC_ALL=C
  local state=$1 job=$2 job_start=$3 origin=$4 status=0 log qfd childfd
  local poll_up='' poll_wall=''
  declare -A loader_previous_cpu=()
  local -a logs
  loader_cancelled=false; loader_bytes=0; loader_job=$job
  unset loader_last_up_cs loader_last_wall_us loader_previous_sample_cs loader_previous_sample_wall_us loader_expected_map loader_previous_end
  loader_output="$state/loader-host/samples.log"
  [[ -d $state/loader-host && ! -L $state/loader-host ]] || return 1
  set -o noclobber
  : > "$loader_output" || return 1
  set +o noclobber
  trap 'loader_cancelled=true' INT TERM
  loader_failure='INCOMPLETE: invalid wrapper uptime origin'
  if [[ ! $origin =~ ^([0-9]{1,10})\.([0-9]{2})$ ]]; then
    printf '%s\n' "$loader_failure" > "$state/loader-host/status.txt"; return 1
  fi
  loader_origin_cs=$((10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]}))
  loader_emit "origin=wrapper_before_children uptime=$origin uptime_view=runner-proc-uptime start_ticks=identity_only" || return 1
  while ! $loader_cancelled; do
    [[ ! -e $state/loader-host/stop ]] || break
    loader_read_clock || break
    loader_failure='INCOMPLETE: runner-proc-uptime stalled across polling interval'
    [[ -z $poll_up ]] || ((loader_up_cs > poll_up)) || break
    loader_failure='INCOMPLETE: runner-EPOCHREALTIME stalled across polling interval'
    [[ -z $poll_wall ]] || ((loader_wall_us > poll_wall)) || break
    poll_up=$loader_up_cs; poll_wall=$loader_wall_us
    loader_failure='INCOMPLETE: job-child or QEMU identity/ancestry unavailable'
    loader_stat "$loader_proc/$job" "$job" && [[ $s_start == "$job_start" ]] || break
    if [[ -f $state/loader-host/test-child.txt ]]; then
      read -r loader_child loader_child_start extra < "$state/loader-host/test-child.txt" || break
      [[ $loader_child =~ ^[1-9][0-9]*$ && $loader_child_start =~ ^[0-9]+$ && -z $extra ]] || break
      loader_stat "$loader_proc/$loader_child" "$loader_child" &&
        [[ $s_start == "$loader_child_start" && $s_parent == "$job" ]] || break
      shopt -s nullglob
      logs=("$state"/os-test-kernel__livepatch-qualification__amd-scale-aged-v5-*/machine-log.log)
      if ((${#logs[@]} > 1)); then break; fi
      if ((${#logs[@]} == 1)) && [[ -e $state/loader-host/request.txt ]]; then
        log=${logs[0]}; loader_launch "$log" || break
        exec {qfd}< "$loader_proc/$loader_pid" || break
        loader_qdir="/proc/$BASHPID/fd/$qfd"
        exec {childfd}< "$loader_proc/$loader_child" || break
        loader_child_dir="/proc/$BASHPID/fd/$childfd"
        loader_child_exe=$(readlink -e "$loader_child_dir/exe") || break
        [[ $loader_child_exe == /nix/store/*/bin/* ]] || break
        loader_emit "baseline=owned_proc_stat required_vcpu_threads=128 CLK_TCK=UNAVAILABLE cpu_units=proc_stat_ticks switches=supplemental runtime=UNAVAILABLE wait=UNAVAILABLE slices=UNAVAILABLE reason=not_collected no_runnable_wait_inference" || break
        loader_snapshot || break
        {
          printf 'qemu %s %s %s\n' "$loader_pid" "$loader_start" "$loader_qemu"
          printf '%s' "$loader_map"
        } > "$state/loader-host/ready.tmp"
        printf 'sampling\n' > "$state/loader-host/status.txt"
        mv -T "$state/loader-host/ready.tmp" "$state/loader-host/ready.txt" || break
        while ! $loader_cancelled; do
          [[ ! -e $state/loader-host/stop ]] || break
          sleep 2
          $loader_cancelled && break
          loader_snapshot || break 2
          if [[ -e $state/loader-host/window-complete.txt ]]; then
            printf 'complete: activation window closed; inspect timestamps and gaps\n' > "$state/loader-host/status.txt"
            exec {qfd}<&-
            exec {childfd}<&-
            trap - INT TERM
            return 0
          fi
        done
        break
      fi
    fi
    sleep 2
  done
  if $loader_cancelled; then loader_failure='INCOMPLETE: sampler stopped by owning job; inspect final sample coverage'; fi
  printf '%s\n' "$loader_failure" > "$state/loader-host/status.txt"
  loader_emit "stop wall=$EPOCHREALTIME reason=$loader_failure" || status=1
  [[ -z ${qfd:-} ]] || exec {qfd}<&-
  [[ -z ${childfd:-} ]] || exec {childfd}<&-
  trap - INT TERM
  return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  [[ $# == 4 ]] || exit 2
  loader_main "$@"
fi

#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 LIVEPATCH_SET_FIXTURE" >&2
  exit 2
fi

fixture=$1
program='/^flags/{found=1; if ($2 !~ /(^|[[:space:]])hypervisor([[:space:]]|$)/) missing=1} END{exit (!found || missing)}'

grep -F \
  "awk -F: '$program' /proc/cpuinfo && printf true" \
  "$fixture" \
  >/dev/null

printf '%s\n' \
  'processor : 0' \
  'flags : fpu vme hypervisor tsc' \
  'processor : 1' \
  'flags : fpu vme hypervisor tsc' \
  | awk -F: "$program"

if printf '%s\n' 'flags : fpu vme tsc' | awk -F: "$program"; then
  echo 'flags without the exact hypervisor token were accepted' >&2
  exit 1
fi

if printf '%s\n' 'processor : 0' 'vendor_id : GenuineIntel' | awk -F: "$program"; then
  echo 'cpuinfo without a flags line was accepted' >&2
  exit 1
fi

printf 'generic livepatch hypervisor-flag admission passed\n'

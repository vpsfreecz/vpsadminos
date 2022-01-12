#!/usr/bin/env bash

log_must() {
  "$@"
  local rc="$?"
  if [ "$rc" != "0" ] ; then
    echo "Command '$@' failed with exit status $rc"
    exit 1
  fi
}

log_mustnot() {
  "$@"
  local rc="$?"
  if [ "$rc" == "0" ] ; then
    echo "Command '$@' succeeded with exit status $rc"
    exit 1
  fi
}

log_fail() {
  echo $@
  exit 1
}

log_pass() {
  echo $@
  exit 0
}

get_prop() {
  local prop="$1"
  local dataset="$2"
  zfs get -H -o value -p "$prop" "$dataset"
  return $?
}

TESTPOOL=tank
TESTFS=testfs

ZFS_USER=zfsugidmap
TEST_UID=100000
TEST_GID=200000

. "$1"/"$2".sh

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

must_have_acl() {
  local acl="$(getfacl $2)"
  if ! grep -x $1 <<< "$acl" ; then
    echo "acl '$1' not found on file '$2'"
    echo "getfacl output:"
    echo "$acl"
    exit 1
  fi
}

must_set_and_have_acl() {
  log_must setfacl -m $1 $2
  must_have_acl $1 $2
}

TESTPOOL=tank
TESTFS=testfs

ZFS_USER=zfsugidmap
TEST_UID=100000
TEST_GID=200000

. "$1"/"$2".sh

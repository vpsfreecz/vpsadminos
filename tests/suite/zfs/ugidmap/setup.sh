log_must zfs create $TESTPOOL/$TESTFS
log_must zfs create $TESTPOOL/$TESTFS/both
log_must zfs create $TESTPOOL/$TESTFS/both/child
log_must zfs create $TESTPOOL/$TESTFS/uid
log_must zfs create $TESTPOOL/$TESTFS/uid/child
log_must zfs create $TESTPOOL/$TESTFS/gid
log_must zfs create $TESTPOOL/$TESTFS/gid/child
log_must zfs create $TESTPOOL/$TESTFS/multimap
log_must zfs create $TESTPOOL/$TESTFS/acl

log_must groupadd -g $TEST_GID $ZFS_USER
log_must useradd -c "ZFS UID/GID Mapping Test User" -u $TEST_UID -g $TEST_GID $ZFS_USER

log_pass

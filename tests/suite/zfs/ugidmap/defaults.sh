[ $(get_prop uidmap $TESTPOOL) == "none" ] || \
    log_fail "uidmap does not default to none"
[ $(get_prop gidmap $TESTPOOL) == "none" ] || \
    log_fail "gidmap does not default to none"

POOLDIR=$(get_prop mountpoint $TESTPOOL)

log_must touch "$POOLDIR/test.txt"
[ $(stat -c %u:%g "$POOLDIR/test.txt") == "0:0" ] || \
    log_fail "maps UIDs/GIDs by default"

log_must chown 50000:60000 "$POOLDIR/test.txt"
[ $(stat -c %u:%g "$POOLDIR/test.txt") == "50000:60000" ] || \
    log_fail "maps UIDs/GIDs by default"

log_must mkdir "$POOLDIR/userdir"
log_must chown $TEST_UID:$TEST_GID "$POOLDIR/userdir"
log_must su $ZFS_USER -c "touch '$POOLDIR/userdir/test.txt'"
[ $(stat -c %u:%g "$POOLDIR/userdir/test.txt") == "$TEST_UID:$TEST_GID" ] || \
    log_fail "maps UIDs/GIDs by default"

# TO TEST:
# default property values
# does not alter uids/gids by default
# cannot change properties while mounted
# can change while unmounted
# shifts uids/gids
# access/read from within/without of the UID/GID range
# maps can be changed
# sending data stream without maps

log_pass

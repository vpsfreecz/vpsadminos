. "$TEST_DIR/setup.sh"

FSDIR=$(get_prop mountpoint $TESTPOOL/$TESTFS)

# uidmap and gidmap can be changed only when the fs is not mounted
log_mustnot zfs set uidmap="0:100000:65536" $TESTPOOL/$TESTFS/both
log_mustnot zfs set gidmap="0:200000:65536" $TESTPOOL/$TESTFS/both
log_must zfs unmount $TESTPOOL/$TESTFS/both

# input checks
for prop in uidmap gidmap ; do
    log_mustnot zfs set ${prop}="" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="something" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="0" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="-1234" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234," $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234,4567" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234,4567" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234:" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234:4567" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234:aha" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="aha:1234" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234:4657:" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234:4657:aha" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234:4657:0" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234:4657:-1" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="-1:-1:-1" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="0:0:0" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234:4657:1," $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}="1234 : 4657 : 1" $TESTPOOL/$TESTFS/both
    log_mustnot zfs set ${prop}=" 1234:4657:1 " $TESTPOOL/$TESTFS/both

    log_must zfs set ${prop}="none" $TESTPOOL/$TESTFS/both
    log_must zfs set ${prop}="1234:4657:1" $TESTPOOL/$TESTFS/both
    log_must zfs set ${prop}="1234:4657:1,5678:9876:2" $TESTPOOL/$TESTFS/both
done

# set a valid map
log_must zfs set uidmap="0:100000:65536" $TESTPOOL/$TESTFS/both
log_must zfs set gidmap="0:200000:65536" $TESTPOOL/$TESTFS/both
log_must zfs mount $TESTPOOL/$TESTFS/both

# both properties should be inheritable
[ $(get_prop uidmap $TESTPOOL/$TESTFS/both/child) == "0:100000:65536" ] || \
    log_fail "uidmap is not inherited"
[ $(get_prop gidmap $TESTPOOL/$TESTFS/both/child) == "0:200000:65536" ] || \
    log_fail "gidmap is not inherited"

# accessing the fs with a user with uid/gid outside the map
log_must touch "$FSDIR/both/test.txt"
owner=$(stat -c %u:%g "$FSDIR/both/test.txt")
[ "$owner" == "100000:200000" ] || \
    log_fail "does not map UIDs/GIDs for new files: expected 100000:200000, got $owner"

log_must chown 500:600 "$FSDIR/both/test.txt"
owner=$(stat -c %u:%g "$FSDIR/both/test.txt")
[ "$owner" == "$((500+100000)):$((600+200000))" ] || \
    log_fail "maps UIDs/GIDs in setattr: expected $((500+100000)):$((600+200000)), got $owner"

# accessing the fs with a user with uid/gid from the map
log_must mkdir "$FSDIR/both/userdir"
log_must chown $TEST_UID:$TEST_GID "$FSDIR/both/userdir"
owner=$(stat -c %u:%g "$FSDIR/both/userdir")
[ "$owner" == "$TEST_UID:$TEST_GID" ] || \
    log_fail "does not map UIDs/GIDs: expected $TEST_UID:$TEST_GID, got $owner"

log_must su $ZFS_USER -c "touch '$FSDIR/both/userdir/test.txt'"
owner=$(stat -c %u:%g "$FSDIR/both/userdir/test.txt")
[ "$owner" == "$TEST_UID:$TEST_GID" ] || \
    log_fail "does not map UIDs/GIDs: expected $TEST_UID:$TEST_GID, got $owner"

log_must zfs unmount $TESTPOOL/$TESTFS/both
log_must zfs set uidmap=none gidmap=none $TESTPOOL/$TESTFS/both
log_must zfs mount $TESTPOOL/$TESTFS/both

owner=$(stat -c %u:%g "$FSDIR/both/test.txt")
[ "$owner" == "500:600" ] || \
    log_fail "UID/GID is persisted mapped: expected 500:600, got $owner"

owner=$(stat -c %u:%g "$FSDIR/both/userdir/test.txt")
[ "$owner" == "$(($TEST_UID-100000)):$(($TEST_GID-200000))" ] || \
    log_fail "UID/GID is persisted mapped: expected $(($TEST_UID-100000)):$(($TEST_GID-200000))"

. "$TEST_DIR/cleanup.sh"
log_pass

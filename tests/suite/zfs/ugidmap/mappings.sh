. "$TEST_DIR/setup.sh"

FSDIR=$(get_prop mountpoint $TESTPOOL/$TESTFS/multimap)

UIDMAP="0:100000:10000,10000:10000:10000,20000:20000:10000,30000:120000:45536"
GIDMAP="0:200000:10000,10000:10000:10000,20000:20000:10000,30000:220000:45536"

log_must zfs unmount $TESTPOOL/$TESTFS/multimap
log_must zfs set uidmap="$UIDMAP" $TESTPOOL/$TESTFS/multimap
log_must zfs set gidmap="$GIDMAP" $TESTPOOL/$TESTFS/multimap
log_must zfs mount $TESTPOOL/$TESTFS/multimap

### Accessing the fs with a user with uid/gid outside the map
log_must touch "$FSDIR/f01.txt"
owner=$(stat -c %u:%g "$FSDIR/f01.txt")
[ "$owner" == "100000:200000" ] || \
    log_fail "does not map UIDs/GIDs for new files: expected 100000:200000, got $owner"

log_must chown 500:600 "$FSDIR/f01.txt"
owner=$(stat -c %u:%g "$FSDIR/f01.txt")
[ "$owner" == "$((500+100000)):$((600+200000))" ] || \
    log_fail "maps UIDs/GIDs in setattr: expected $((500+100000)):$((600+200000)), got $owner"

### Accessing the fs with a user with uid/gid from the map, testing boundaries
#### of all map entries
# First map entry
log_must mkdir "$FSDIR/dir"
log_must chown $TEST_UID:$TEST_GID "$FSDIR/dir"
owner=$(stat -c %u:%g "$FSDIR/dir")
[ "$owner" == "$TEST_UID:$TEST_GID" ] || \
    log_fail "does not map UIDs/GIDs: expected $TEST_UID:$TEST_GID, got $owner"

log_must su $ZFS_USER -c "touch '$FSDIR/dir/first_start.txt'"
owner=$(stat -c %u:%g "$FSDIR/dir/first_start.txt")
[ "$owner" == "$TEST_UID:$TEST_GID" ] || \
    log_fail "does not map UIDs/GIDs: expected $TEST_UID:$TEST_GID, got $owner"

log_must touch $FSDIR/dir/first_end.txt
log_must chown 109999:209999 $FSDIR/dir/first_end.txt
owner=$(stat -c %u:%g "$FSDIR/dir/first_end.txt")
[ "$owner" == "109999:209999" ] || \
    log_fail "does not map UIDs/GIDs: expected 109999:209999, got $owner"

# Second map entry
log_must touch $FSDIR/dir/second_start.txt
log_must chown 10000:10000 $FSDIR/dir/second_start.txt
owner=$(stat -c %u:%g "$FSDIR/dir/second_start.txt")
[ "$owner" == "10000:10000" ] || \
    log_fail "does not map UIDs/GIDs: expected 10000:10000, got $owner"

log_must touch $FSDIR/dir/second_end.txt
log_must chown 19999:19999 $FSDIR/dir/second_end.txt
owner=$(stat -c %u:%g "$FSDIR/dir/second_end.txt")
[ "$owner" == "19999:19999" ] || \
    log_fail "does not map UIDs/GIDs: expected 19999:19999, got $owner"

# Third map entry
log_must touch $FSDIR/dir/third_start.txt
log_must chown 20000:20000 $FSDIR/dir/third_start.txt
owner=$(stat -c %u:%g "$FSDIR/dir/third_start.txt")
[ "$owner" == "20000:20000" ] || \
    log_fail "does not map UIDs/GIDs: expected 20000:20000, got $owner"

log_must touch $FSDIR/dir/third_end.txt
log_must chown 29999:29999 $FSDIR/dir/third_end.txt
owner=$(stat -c %u:%g "$FSDIR/dir/third_end.txt")
[ "$owner" == "29999:29999" ] || \
    log_fail "does not map UIDs/GIDs: expected 29999:29999, got $owner"

# Last map entry
log_must touch $FSDIR/dir/last_start.txt
log_must chown 30000:30000 $FSDIR/dir/last_start.txt
owner=$(stat -c %u:%g "$FSDIR/dir/last_start.txt")
[ "$owner" == "120000:220000" ] || \
    log_fail "does not map UIDs/GIDs: expected 120000:220000, got $owner"

log_must touch $FSDIR/dir/last_end.txt
log_must chown 65535:65535 $FSDIR/dir/last_end.txt
owner=$(stat -c %u:%g "$FSDIR/dir/last_end.txt")
[ "$owner" == "155535:255535" ] || \
    log_fail "does not map UIDs/GIDs: expected 155535:255535, got $owner"


### Test that mapped uid/gids are not persisted
log_must zfs unmount $TESTPOOL/$TESTFS/multimap
log_must zfs set uidmap=none gidmap=none $TESTPOOL/$TESTFS/multimap
log_must zfs mount $TESTPOOL/$TESTFS/multimap

owner=$(stat -c %u:%g "$FSDIR/f01.txt")
[ "$owner" == "500:600" ] || \
    log_fail "UID/GID is persisted mapped: expected 500:600, got $owner"

# First map entry
owner=$(stat -c %u:%g "$FSDIR/dir/first_start.txt")
[ "$owner" == "0:0" ] || \
    log_fail "UID/GID is persisted mapped: expected 0:0, got $owner"

owner=$(stat -c %u:%g "$FSDIR/dir/first_end.txt")
[ "$owner" == "9999:9999" ] || \
    log_fail "UID/GID is persisted mapped: expected 9999:9999, got $owner"

# Second map entry
owner=$(stat -c %u:%g "$FSDIR/dir/second_start.txt")
[ "$owner" == "10000:10000" ] || \
    log_fail "UID/GID is persisted mapped: expected 10000:10000, got $owner"

owner=$(stat -c %u:%g "$FSDIR/dir/second_end.txt")
[ "$owner" == "19999:19999" ] || \
    log_fail "UID/GID is persisted mapped: expected 19999:19999, got $owner"

# Third map entry
owner=$(stat -c %u:%g "$FSDIR/dir/third_start.txt")
[ "$owner" == "20000:20000" ] || \
    log_fail "UID/GID is persisted mapped: expected 20000:20000, got $owner"

owner=$(stat -c %u:%g "$FSDIR/dir/third_end.txt")
[ "$owner" == "29999:29999" ] || \
    log_fail "UID/GID is persisted mapped: expected 29999:29999, got $owner"

# Last map entry
owner=$(stat -c %u:%g "$FSDIR/dir/last_start.txt")
[ "$owner" == "30000:30000" ] || \
    log_fail "UID/GID is persisted mapped: expected 30000:30000, got $owner"

owner=$(stat -c %u:%g "$FSDIR/dir/last_end.txt")
[ "$owner" == "65535:65535" ] || \
    log_fail "UID/GID is persisted mapped: expected 65535:65535, got $owner"

. "$TEST_DIR/cleanup.sh"
log_pass

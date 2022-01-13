TESTDS=$TESTPOOL/$TESTFS/acl
FSDIR=$(get_prop mountpoint $TESTDS)

# The correct file is unmapped on disk and mapped with mapping enabled
CORRECT_FILE=$FSDIR/correct

# The wrong file is a result of a bug in the ugidmap patch, where mappings
# weren't checked at all. Mapped entries are written to disk.
WRONG_FILE=$FSDIR/wrong

# The new file will be created when mapping is enabled
NEW_HOST_FILE=$FSDIR/new-host
NEW_MAPPED_FILE=$FSDIR/new-mapped

UIDMAP="0:$TEST_UID:65536"
GIDMAP="0:$TEST_GID:65536"

CORRECT_UID=33
CORRECT_GID=66

MAPPED_UID=$(($TEST_UID + $CORRECT_UID))
MAPPED_GID=$(($TEST_GID + $CORRECT_GID))

WRONG_UID=$MAPPED_UID
WRONG_GID=$MAPPED_GID

###
# log_must zfs destroy -r $TESTDS
# log_must zfs create $TESTDS
###

log_must zfs set acltype=posixacl $TESTDS

### Without any uidmap/gidmap
log_must touch $CORRECT_FILE
log_must touch $WRONG_FILE

must_set_and_have_acl user:$CORRECT_UID:rwx $CORRECT_FILE
must_set_and_have_acl group:$CORRECT_GID:rwx $CORRECT_FILE

must_set_and_have_acl user:$WRONG_UID:rwx $WRONG_FILE
must_set_and_have_acl group:$WRONG_GID:rwx $WRONG_FILE

### With uidmap/gidmap, both should now appear ok
log_must zfs umount $TESTDS
log_must zfs set uidmap=$UIDMAP gidmap=$GIDMAP $TESTDS
log_must zfs mount $TESTDS

must_have_acl user:$MAPPED_UID:rwx $CORRECT_FILE
must_have_acl group:$MAPPED_GID:rwx $CORRECT_FILE

must_have_acl user:$MAPPED_UID:rwx $WRONG_FILE
must_have_acl group:$MAPPED_GID:rwx $WRONG_FILE

# Create a new acl
touch $NEW_HOST_FILE
touch $NEW_MAPPED_FILE

log_must setfacl -m user:$CORRECT_UID:rwx $NEW_HOST_FILE
must_have_acl user:$MAPPED_UID:rwx $NEW_HOST_FILE
log_must setfacl -m group:$CORRECT_GID:rwx $NEW_HOST_FILE
must_have_acl group:$MAPPED_GID:rwx $NEW_HOST_FILE

log_must su $ZFS_USER -c "setfacl -m user:$CORRECT_UID:rwx $NEW_MAPPED_FILE"
log_must su $ZFS_USER -c "setfacl -m group:$CORRECT_GID:rwx $NEW_MAPPED_FILE"

must_have_acl user:$MAPPED_UID:rwx $NEW_MAPPED_FILE
must_have_acl group:$MAPPED_GID:rwx $NEW_MAPPED_FILE

### Unset mapping
log_must zfs umount $TESTDS
log_must zfs set uidmap=none gidmap=none $TESTDS
log_must zfs mount $TESTDS

must_have_acl user:$CORRECT_UID:rwx $CORRECT_FILE
must_have_acl group:$CORRECT_GID:rwx $CORRECT_FILE

must_have_acl user:$WRONG_UID:rwx $WRONG_FILE
must_have_acl group:$WRONG_GID:rwx $WRONG_FILE

must_have_acl user:$CORRECT_UID:rwx $NEW_HOST_FILE
must_have_acl group:$CORRECT_GID:rwx $NEW_HOST_FILE

must_have_acl user:$CORRECT_UID:rwx $NEW_MAPPED_FILE
must_have_acl group:$CORRECT_GID:rwx $NEW_MAPPED_FILE

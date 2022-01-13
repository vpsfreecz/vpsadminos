log_must zfs destroy -r $TESTPOOL/$TESTFS
log_must userdel $ZFS_USER
log_must groupdel $ZFS_USER

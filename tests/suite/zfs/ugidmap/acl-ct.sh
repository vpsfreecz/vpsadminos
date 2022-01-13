UIDMAP="0:$TEST_UID:65536"
GIDMAP="0:$TEST_GID:65536"

CT_USER_UID=1000
CT_GROUP_GID=2000

log_must osctl user new --map-uid $UIDMAP --map-gid $GIDMAP testuser
log_must osctl ct new --user testuser --distribution alpine testct
log_must osctl ct netif new bridge --link lxcbr0 testct eth0
log_must osctl ct start testct
log_must sleep 10

CT_DS=$(osctl ct show -H -o dataset testct)
CT_ROOTFS=$(osctl ct show -H -o rootfs testct)

log_must zfs set acltype=posixacl $CT_DS

# Check ACL in a running container
log_must osctl ct runscript testct - <<END
#!/bin/sh
fail() {
  echo \$@
  exit 1
}

apk add acl

addgroup -g $CT_GROUP_GID testgroup
adduser -u $CT_USER_UID -G testgroup -D testuser

mkdir -p /acl /acl/user /acl/group
chmod og-rwx /acl/user /acl/group || fail "chmod failed"

su testuser -c "ls -l /acl/user" && fail "can access /acl/user"
su testuser -c "ls -l /acl/group" && fail "can access /acl/group"

setfacl -m user:testuser:rx /acl/user

su testuser -c "ls -l /acl/user" || fail "user acl has no effect"
su testuser -c "ls -l /acl/group" && fail "can access /acl/group"

setfacl -m group:testgroup:rx /acl/group

su testuser -c "ls -l /acl/user" || fail "user acl has no effect"
su testuser -c "ls -l /acl/group" || fail "group acl has no effect"

getfacl /acl/user | grep -x user:testuser:r-x \
  || fail "user ACL not recognized"

getfacl /acl/group | grep -x group:testgroup:r-x \
  || fail "group ACL not recognized"

setfacl -b /acl/user
setfacl -b /acl/group

su testuser -c "ls -l /acl/user" && fail "user acl wasn't unset"
su testuser -c "ls -l /acl/group" && fal "group acl wasn't unset"

setfacl -m user:testuser:rx /acl/user
setfacl -m group:testgroup:rx /acl/group

mkdir /acl/default-user /acl/default-group
setfacl -d -m user:testuser:rx /acl/default-user
mkdir -m 0700 /acl/default-user/dir
setfacl -m mask::rwx /acl/default-user/dir
su testuser -c "ls -l /acl/default-user/dir" || fail "/acl/default-user/dir not accessible"

setfacl -d -m group:testgroup:rx /acl/default-group
mkdir -m 0700 /acl/default-group/dir
setfacl -m mask::rwx /acl/default-group/dir
su testuser -c "ls -l /acl/default-group/dir" || fail "/acl/default-group/dir not accessible"

exit 0
END

# Check on-disk ACL when the container is stopped & unmapped
log_must osctl ct stop testct

log_must zfs umount $CT_DS
log_must zfs set uidmap=none gidmap=none $CT_DS
log_must zfs mount $CT_DS

must_have_acl user:$CT_USER_UID:r-x $CT_ROOTFS/acl/user
must_have_acl group:$CT_GROUP_GID:r-x $CT_ROOTFS/acl/group

# Create acl with already-mapped entries. These are ACLs that have been created
# by a version of the ZFS UID/GID mapping patch which did not map ACLs at all.
mkdir $CT_ROOTFS/acl/old-preexisting
setfacl -m user:$(($TEST_UID + $CT_USER_UID)):rx $CT_ROOTFS/acl/old-preexisting
setfacl -m group:$(($TEST_GID + $CT_GROUP_GID)):rx $CT_ROOTFS/acl/old-preexisting

must_have_acl default:user:$CT_USER_UID:r-x $CT_ROOTFS/acl/default-user
must_have_acl default:group:$CT_GROUP_UID:r-x $CT_ROOTFS/acl/default-group

must_have_acl user:$CT_USER_UID:r-x $CT_ROOTFS/acl/default-user/dir
must_have_acl group:$CT_GROUP_UID:r-x $CT_ROOTFS/acl/default-group/dir

# Set the map again, start the container and re-check
log_must zfs umount $CT_DS
log_must zfs set uidmap=$UIDMAP gidmap=$GIDMAP $CT_DS
log_must zfs mount $CT_DS
log_must osctl ct start testct

log_must osctl ct runscript testct - <<EOF
#!/bin/sh

fail() {
  echo \$@
  exit 1
}

su testuser -c "ls -l /acl/user" || fail "user acl has no effect"
su testuser -c "ls -l /acl/group" || fail "group acl has no effect"

getfacl /acl/old-preexisting | grep -x user:testuser:r-x \
  || fail "preexisting user ACL not recognized"

getfacl /acl/old-preexisting | grep -x group:testgroup:r-x \
  || fail "preexisting group ACL not recognized"

exit 0
EOF

log_must osctl ct del -f testct
log_must osctl user del testuser

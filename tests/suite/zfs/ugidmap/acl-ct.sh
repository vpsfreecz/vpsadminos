UIDMAP="0:$TEST_UID:65536"
GIDMAP="0:$TEST_GID:65536"

CT_USER_UID=1000
CT_GROUP_GID=2000

log_must osctl ct user new --uid-map $UIDMAP --gid-map $GIDMAP testuser
log_must osctl ct new --user testuser --distribution alpine testct
log_must osctl ct netif new bridge --link lxcbr0 testct eth0
log_must osctl ct start testct
log_must sleep 10

# Check ACL in a running container
log_must osctl ct runscript testct - <<END
#!/bin/sh
fail() {
  echo \$@
  exit 1
}

apk add acl

addgroup -g $CT_GROUP_GID testgroup
adduser -u $CT_USER_UID -g testgroup -D testuser

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

setfacl -b /acl/user
setfacl -b /acl/group

su testuser -c "ls -l /acl/user" && fail "user acl wasn't unset"
su testuser -c "ls -l /acl/group" && fal "group acl wasn't unset"

setfacl -m user:testuser:rx /acl/user
setfacl -m group:testgroup:rx /acl/group
END

# Check on-disk ACL when the container is stopped & unmapped
log_must osctl ct stop testct

CT_DS=$(osctl ct show -H -o dataset testct)
CT_ROOTFS=$(osctl ct show -H -o rootfs testct)

log_must zfs umount $CT_DS
log_must zfs set uidmap=none gidmap=none $CT_DS
log_must zfs mount $CT_DS

must_have_acl user:$CT_USER_UID:rx $CT_ROOTFS/acl/user
must_have_acl group:$CT_GROUP_GID:rx $CT_ROOTFS/acl/group

# Create acl with already-mapped entries. These are ACLs that have been created
# by a version of the ZFS UID/GID mapping patch which did not map ACLs at all.
mkdir $CT_ROOTFS/acl/old-preexisting
setfacl -m user:$(($TEST_UID + $CT_USER_UID)):rx $CT_ROOTFS/acl/old-preexisting
setfacl -m group:$(($TEST_GID + $CT_GROUP_GID)):rx $CT_ROOTFS/acl/old-preexisting

# Set the map again, start the container and re-check
log_must zfs umount $CT_DS
log_must zfs set uidmap=$UIDMAP gidmap=$GIDMAP $CT_DS
log_must zfs mount $CT_DS
log_must osctl ct start testct

log_must osctl ct runscript - <<EOF
#!/bin/sh

fail() {
  echo \$@
  exit 1
}

su testuser -c "ls -l /acl/user" || fail "user acl has no effect"
su testuser -c "ls -l /acl/group" || fail "group acl has no effect"

getfacl /acl/old-preexisting | grep -x user:testuser:rx \
  || fail "preexisting user ACL not recognized"

getfacl /acl/old-preexisting | grep -x group:testgroup:rx \
  || fail "preexisting group ACL not recognized"
EOF

log_must osctl ct del -f testct
log_must osctl user del -f testuser

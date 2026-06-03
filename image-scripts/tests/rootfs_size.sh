MAX_ROOTFS_SIZE=$((1024 * 1024 * 1024))

dataset=$(osctl ct show -H -o dataset "$CTID") \
	|| fail "unable to get rootfs dataset"
used=$(zfs get -Hp -o value used "$dataset") \
	|| fail "unable to get rootfs dataset usage"

if [ "$used" -gt "$MAX_ROOTFS_SIZE" ] ; then
	fail "rootfs dataset uses ${used} bytes, limit is ${MAX_ROOTFS_SIZE} bytes"
fi

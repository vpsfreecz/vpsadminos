cgroup_mode() {
	if grep -x "^[[:digit:]]:cpuset:/" /proc/1/cgroup > /dev/null ; then
		echo "hybrid"
	else
		echo "unified"
	fi
}

cgroup_setup_hybrid() {
	msg "Mounting cgroups in a hybrid layout"

	local retval=0
	local name
	local hybrid_cgroups="blkio
cglimit
cpu,cpuacct
cpuset
devices
freezer
hugetlb
memory
net_cls,net_prio
perf_event
pids
rdma"
	local hybrid_named="systemd"
	local mount_opts="nodev,noexec,nosuid"

	if ! mount -t tmpfs -o "$mount_opts" tmpfs /sys/fs/cgroup ; then
		msg_warn "Unable to mount /sys/fs/cgroup"
		return 1
	fi

	for name in $hybrid_cgroups; do
		mkdir "/sys/fs/cgroup/$name"
		mount -n -t cgroup -o "$mount_opts,$name" \
			cgroup "/sys/fs/cgroup/$name" || retval=1
	done

	for name in $hybrid_named; do
		mkdir "/sys/fs/cgroup/$name"
		mount -n -t cgroup -o "none,$mount_opts,name=$name" \
			cgroup "/sys/fs/cgroup/$name" || retval=1
	done

	mount -o remount,ro tmpfs /sys/fs/cgroup

	return $retval
}

cgroup_setup_unified() {
	msg "Mounting cgroups in a unified layout"

	mkdir /sys/fs/cgroup/init.scope
	echo 1 > /sys/fs/cgroup/init.scope/cgroup.procs
}

case "$(cgroup_mode)" in
	hybrid) cgroup_setup_hybrid ;;
	unified) cgroup_setup_unified ;;
	*) msg_warn "Unknown cgroup mode" ;;
esac

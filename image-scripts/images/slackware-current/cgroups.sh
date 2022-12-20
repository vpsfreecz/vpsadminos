#!/bin/sh

cgroup_mode() {
	if grep -x "^[[:digit:]]:cpuset:/" /proc/1/cgroup > /dev/null ; then
		echo "hybrid"
	else
		echo "unified"
	fi
}

cgroup_setup_hybrid() {
	echo "Mounting cgroups in a hybrid layout"

	local retval=0
	local name
	local hybrid_cgroups="blkio
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
		echo "Unable to mount /sys/fs/cgroup"
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

	mkdir /sys/fs/cgroup/unified
	mount -n -t cgroup2 -o "$mount_opts" cgroup2 /sys/fs/cgroup/unified || retval=1

	ln -s systemd /sys/fs/cgroup/elogind
	mount -o remount,ro tmpfs /sys/fs/cgroup

	return $retval
}

cgroup_setup_unified() {
	echo "Mounting cgroups in a unified layout"

	mkdir /sys/fs/cgroup/init.scope
	echo 1 > /sys/fs/cgroup/init.scope/cgroup.procs
}

case "$(cgroup_mode)" in
	hybrid) cgroup_setup_hybrid ;;
	unified) cgroup_setup_unified ;;
	*) echo "Unknown cgroup mode" ;;
esac

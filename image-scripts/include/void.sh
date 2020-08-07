require_cmd wget

BASEURL=http://alpha.de.repo.voidlinux.org/live/current
ROOTFS=

fetch() {
	local name
	local rx

	if [ "$VARIANT" == "musl" ] ; then
		rx='void-x86_64-musl-ROOTFS-\d+.tar.xz'
	else
		rx='void-x86_64-ROOTFS-\d+.tar.xz'
	fi

	# Fetch checksums to find out latest release name
	wget -O - "$BASEURL/sha256.txt" | grep -P "$rx" > "$DOWNLOAD/sha256.txt"

	# Extract the name
	name=$(grep -o -P "$rx" "$DOWNLOAD/sha256.txt")

	# Download rootfs
	wget -P "$DOWNLOAD" "$BASEURL/$name"

	if ! (cd "$DOWNLOAD" ; sha256sum -c sha256.txt) ; then
		warn "Checksum does not match"
		exit 1
	fi

	ROOTFS="$DOWNLOAD/$name"
}

extract() {
	tar -xJf "$ROOTFS" -C "$INSTALL"
}

configure-void() {
	configure-append <<EOF
echo nameserver 8.8.8.8 > /etc/resolv.conf
xbps-install -Syu
xbps-install -Syu
xbps-install -Syu libcgroup-utils vim
cp /etc/skel/.[^.]* /root/
usermod -s /bin/bash root
usermod -L root
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
ln -s /etc/sv/sshd /etc/runit/runsvdir/default/sshd
rm -f /etc/runit/runsvdir/default/agetty-tty{1..6}
rm -f /etc/runit/runsvdir/default/udevd
ln -s /etc/sv/agetty-console /etc/runit/runsvdir/default/agetty-console
echo > /etc/resolv.conf

cat <<END > /etc/cgconfig.conf
mount {
   cpuset = /sys/fs/cgroup/cpuset;
   cpu = /sys/fs/cgroup/cpu,cpuacct;
   cpuacct = /sys/fs/cgroup/cpu,cpuacct;
   blkio = /sys/fs/cgroup/blkio;
   memory = /sys/fs/cgroup/memory;
   devices = /sys/fs/cgroup/devices;
   freezer = /sys/fs/cgroup/freezer;
   net_cls = /sys/fs/cgroup/net_cls,net_prio;
   net_prio = /sys/fs/cgroup/net_cls,net_prio;
   pids = /sys/fs/cgroup/pids;
   perf_event = /sys/fs/cgroup/perf_event;
   rdma = /sys/fs/cgroup/rdma;
   hugetlb = /sys/fs/cgroup/hugetlb;
   cglimit = /sys/fs/cgroup/cglimit;
   "name=systemd" = /sys/fs/cgroup/systemd;
}
END

cat <<END > /etc/runit/core-services/10-vpsadminos-cgroups.sh
msg "Mounting /sys/fs/cgroup"
mount -t tmpfs tmpfs /sys/fs/cgroup
cgconfigparser -l /etc/cgconfig.conf
END
EOF
}

generate-void() {
	fetch
	extract
	configure-shebang "#!/bin/bash"
	configure-common
	configure-void
	run-configure
}

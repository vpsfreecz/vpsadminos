# Slackware 15.0
#
# 1. Download FILELIST.txt and CHECKSUMS.md5 from remote repository, use these
#    to download installed packages
# 2. Install pkgtools to the $DOWNLOAD directory (not in the new rootfs)
# 3. Use the installpkg from pkgtools to install the base system within
#    the rootfs
# 4. Chroot, setup slackpkg, upgrade the system and install extra packages,
#    additional configuration and patching
#
# We bring in our own script to mount cgroups, see /etc/rc.d/rc.vpsadminos.cgroups.
#
# /etc/rc.d/rc.M (multi-user runlevel) starts the original /etc/rc.d/rc.inet1
# script that brings up the loopback. It has been patched to start our custom
# script /etc/rc.d/rc.venet. This script can start/stop/restart the venet0
# interface. It executes /etc/rc.d/rc.venet.start on start and
# /etc/rc.d/rc.venet.stop on stop.
#
# These scripts are responsible for configuring the interface and are generated
# by osctld. rc.venet.{start,stop} scripts configure the interface using
# /sbin/ip commands (needs package iproute2). The contents of these files is
# rewritten on VPS start and on osctl ct netif ip add/del commands.

. "$IMAGEDIR/config.sh"
SLACKWARE_POWER_PACKAGE_AFTER_GAWK=genpower
SLACKWARE_POWER_PACKAGE_AFTER_NETWORK_SCRIPTS=
. "$INCLUDE/slackware.sh"

slackware-bootstrap

configure-shebang '#!/bin/bash'
configure-append <<EOF
set -ex
EOF
configure-common
configure-append <<EOF
export USER=root
export HOME=/root

# As the base system is installed from outside, group 'shadow' does not
# exist at that time and doinst.sh of package 'etc' fails in this step.
chown root.shadow /etc/shadow /etc/gshadow

echo nameserver 8.8.8.8 > /etc/resolv.conf

/usr/sbin/update-ca-certificates --fresh

# Setup slackpkg
sed -i -r 's/^# (https:\/\/mirrors.slackware.com\/slackware\/slackware64-$RELVER\/)$/\1/' /etc/slackpkg/mirrors
slackpkg -batch=on -default_answer=y update gpg
slackpkg -batch=on -default_answer=y update
slackpkg -batch=on -default_answer=y upgrade slackpkg
slackpkg -batch=on -default_answer=y upgrade aaa_glibc-solibs

# Use new configuration files, O as overwrite
echo O | slackpkg -batch=on new-config

# Reconfigure mirror
sed -i -r 's/^# (https:\/\/mirrors.slackware.com\/slackware\/slackware64-$RELVER\/)$/\1/' /etc/slackpkg/mirrors

slackpkg -batch=on -default_answer=y update
slackpkg -batch=on -default_answer=y upgrade-all

# Use new configuration files, O as overwrite
echo O | slackpkg -batch=on new-config

# Delete old configuration files
find /etc -name "*.orig" -delete

echo > /etc/fstab

# Remote console
sed -i '/^c1:/c\c1:12345:respawn:\/sbin\/agetty --noclear 38400 console linux' /etc/inittab
sed -i -r 's/^(c[2-6]:)/#\1/g' /etc/inittab

# Power
sed -i 's|pf::powerfail:/sbin/genpowerfail start|pf::powerwait:/sbin/halt|' /etc/inittab

# Configure SSH
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Mount /run
sed -i \
	's|if \[ -d /run -a -z "\$container" \]; then|# Mount /run on vpsAdminOS\nif \[ -d /run \]; then|' \
	/etc/rc.d/rc.S

# Custom cgroup setup script
sed -i \
	'/^# Mount Control Groups filesystem interface:/a if \[ -x /etc/rc.d/rc.vpsadminos.cgroups \] ; then\n\
  \/etc\/rc.d\/rc.vpsadminos.cgroups start\n\
fi\n' \
	/etc/rc.d/rc.S
chmod +x /etc/rc.d/rc.vpsadminos.cgroups

# Custom network setup script
sed -i '/^# Start networking daemons:$/i \
# Setup osctl network\n\
if \[ -x \/etc\/rc.d\/rc.venet \] ; then\n\
    \/etc\/rc.d\/rc.venet start\n\
fi\n\

' /etc/rc.d/rc.M

cat <<EOT > /etc/rc.d/rc.venet
#!/bin/sh
case "\\\$1" in
	start|stop)
		[ -f "/etc/rc.d/rc.venet.\\\$1" ] && . "/etc/rc.d/rc.venet.\\\$1"
		;;
	restart)
		if [ -f /etc/rc.d/rc.venet.start ] && [ -f /etc/rc.d/rc.venet.stop ] ; then
			. /etc/rc.d/rc.venet.stop
			. /etc/rc.d/rc.venet.start
		fi
		;;
	*)
		echo "Usage: \\\$0 start|stop|restart"
		;;
esac

EOT

chmod +x /etc/rc.d/rc.venet

if [ ! -f /sbin/modprobe ] ; then
  cat <<EOT > /sbin/modprobe
#!/bin/sh
# This is a /sbin/modprobe shim provided by vpsAdminOS. This system is expected
# to run as a container, which cannot load its own modules.
exit 0
EOT
  chmod +x /sbin/modprobe
fi

# Enable Ctrl-left-arrow and Ctrl-right-arrow navigation in bash
cat <<EOT >> /etc/inputrc

# mappings for Ctrl-left-arrow and Ctrl-right-arrow for word moving
"\e[1;5C": forward-word
"\e[1;5D": backward-word
"\e[5C": forward-word
"\e[5D": backward-word
"\e\e[C": forward-word
"\e\e[D": backward-word
EOT

usermod -L root
echo > /etc/resolv.conf
EOF
run-configure
configure_status=$?
if [ "$configure_status" -ne 0 ] ; then
	warn "Unable to configure Slackware $RELVER"
	exit "$configure_status"
fi

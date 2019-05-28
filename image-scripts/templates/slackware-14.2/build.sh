# Slackware 14.2
#
# 1. Download FILELIST.txt and CHECKSUMS.md5 from remote repository, use these
#    to download installed packages
# 2. Install pkgtools to the $DOWNLOAD directory (not in the new rootfs)
# 3. Use the installpkg from pkgtools to install the base system within
#    the rootfs
# 4. Chroot, setup slackpkg, upgrade the system and install extra packages,
#    additional configuration and patching
#
# Slackware's built-in network scripts do not support setting multiple IPv4
# addresses on one interface and IPv6 is not supported at all.
# For this reason, this template provides its own script to setup venet0 and
# add IP addresses.
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

. "$TEMPLATEDIR/config.sh"
BASEURL=http://mirrors.slackware.com/slackware/
LOCAL_REPO="$DOWNLOAD/repo"
LOCAL_ROOT="$DOWNLOAD/root"
INSTALLPKG=
PKGS="
aaa_base
aaa_elflibs
aaa_terminfo
attr
bash
bin
bzip2
ca-certificates
coreutils
cpio
dcron
devs
dialog
diffutils
dhcpcd
etc
file
findutils
gawk
genpower
glibc-solibs
glibc-zoneinfo
gnupg
gnutls
grep
groff
gzip
iproute2
iputils
less
libmpc
libffi
libtermcap
libunistring
logrotate
man
man-pages
mpfr
nano
ncurses
net-tools
nettle
network-scripts
openssh
n/openssl
a/openssl-solibs
p11-kit
perl
pkgtools
procps
python
readline
sed
shadow
slackpkg
sysklogd
sysvinit
sysvinit-scripts
tar
util-linux
vim
wget
which
xz
"

require_cmd wget

download_index() {
	mkdir -p "$LOCAL_REPO"
	wget -O "$LOCAL_REPO/FILELIST.txt" $BASEURL/slackware64-$RELVER/FILELIST.TXT
	wget -O "$LOCAL_REPO/CHECKSUMS.md5" $BASEURL/slackware64-$RELVER/CHECKSUMS.md5
}

download_pkg() {
	if [[ "$1" == *"/"* ]] ; then
		local pkg=`find "$LOCAL_REPO" -type f -wholename "*/$1-*.t?z" | head -n1`
	else
		local pkg=`find "$LOCAL_REPO" -type f -name "$1-*.t?z" | head -n1`
	fi

	if [ "$pkg" != "" ] ; then
		echo $pkg
		exit
	fi

	if [[ "$1" == *"/"* ]] ; then
		local path=`grep -P "./slackware64/$1\-.+\.t.z$" "$LOCAL_REPO/FILELIST.txt" | awk '{ print $8; }' | head -n1`
	else
		local path=`grep -P "./slackware64/[^/]+/$1\-.+\.t.z$" "$LOCAL_REPO/FILELIST.txt" | awk '{ print $8; }' | head -n1`
	fi

	if [ "$path" == "" ] ; then
		warn "Package '$1' not found"
		exit 1
	fi

	mkdir -p "$LOCAL_REPO/$(dirname $path)"
	wget -O "$LOCAL_REPO/$path" $BASEURL/slackware64-$RELVER/$path

	if ! (cd "$LOCAL_REPO" ; grep "$path$" CHECKSUMS.md5 | md5sum -c > /dev/null)
	then
		warn "$1 checksum invalid"
		exit 1
	fi

	echo "$LOCAL_REPO/$path"
}

setup_pkgtools() {
	mkdir -p "$LOCAL_ROOT"

	pkg="`download_pkg pkgtools`"
	[ "$?" != "0" ] && exit 1

	tar -xJf "$pkg" -C "$LOCAL_ROOT"
	INSTALLPKG="$LOCAL_ROOT/sbin/installpkg"
}

install_pkg() {
	pkg=`download_pkg $1`
	[ "$?" != "0" ] && exit 1

	$INSTALLPKG --terse --root "$INSTALL" $pkg
}


download_index || exit 1

# Install pkgtools outside the rootfs
setup_pkgtools || exit 1

# Install all packages in the rootfs
for pkg in $PKGS ; do
	echo "Installing $pkg"
	install_pkg $pkg

	if [ "$?" != "0" ] ; then
		warn "Unable to install '$pkg'"
		exit 1
	fi
done

configure-common
configure-append <<EOF
# As the base system is installed from outside, group 'shadow' does not
# exist at that time and doinst.sh of package 'etc' fails in this step.
chown root.shadow /etc/shadow /etc/gshadow

echo nameserver 8.8.8.8 > /etc/resolv.conf

# Slackware ships with old certificates that don't work with current https
# mirror
/usr/sbin/update-ca-certificates --fresh

# Setup slackpkg
sed -i -r 's/^# (http:\/\/mirrors.slackware.com\/slackware\/slackware64-$RELVER\/)$/\1/' /etc/slackpkg/mirrors
slackpkg -batch=on -default_answer=y update
slackpkg -batch=on -default_answer=y upgrade slackpkg
slackpkg -batch=on -default_answer=y upgrade glibc-solibs

# Use new configuration files, O as overwrite
echo O | slackpkg new-config

# Reconfigure mirror
sed -i -r 's/^# (http:\/\/mirrors.slackware.com\/slackware\/slackware64-$RELVER\/)$/\1/' /etc/slackpkg/mirrors

slackpkg -batch=on -default_answer=y update
slackpkg -batch=on -default_answer=y upgrade-all

# Use new configuration files, O as overwrite
echo O | slackpkg new-config

# Delete old configuration files
find /etc -name "*.orig" -delete

# hwclock is not available
sed -i -e '/^if \[ -x \/sbin\/hwclock/,/^fi$/s/^/#/' /etc/rc.d/rc.S
sed -i -e '/^if \[ -x \/sbin\/hwclock/,/^fi$/s/^/#/' /etc/rc.d/rc.6

# Do not test if the rootfs is read-only, as it never is
sed -i -e '/^if touch \/fsrwtestfile/,/^fi$/s/^/#/' /etc/rc.d/rc.S
sed -i -e '/^if \[ ! \$READWRITE = yes/,/^fi # Done checking root filesystem/s/^/#/' /etc/rc.d/rc.S

# Disable setterm
sed -i -e '/^\/bin\/setterm/s/^/#/' /etc/rc.d/rc.M

echo > /etc/fstab

# Remote console
sed -i '/^c1:/c\c1:12345:respawn:\/sbin\/agetty --noclear 38400 console linux' /etc/inittab
sed -i -r 's/^(c[2-6]:)/#\1/g' /etc/inittab

# Power
sed -i 's|pf::powerfail:/sbin/genpowerfail start|pf::powerwait:/sbin/halt|' /etc/inittab

# Configure SSH
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Skip fsck
touch /etc/fastboot

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

# Lock root account
usermod -L root

echo > /etc/resolv.conf
EOF
run-configure

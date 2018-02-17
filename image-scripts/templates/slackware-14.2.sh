# Slackware 14.2
#
# 1. Download categories a, ab, l and n from a remote repository (~300 MB)
# 2. Install pkgtools to the $DOWNLOAD directory (not in the new rootfs)
# 3. Use the installpkg from pkgtools to install the base system within
#    the rootfs
# 4. Chroot, setup slackpkg, upgrade the system and install extra packages,
#    additional configuration and patching
#
# Slackware's built-in network scripts do not support setting multiple IPv4
# addresses on one interface and IPv6 is not supported at all.
# For this reason, this template provides its own script to setup venet0 and
# add IP addresses. A patched version of vzctl is needed to use this custom
# script.
#
# /etc/rc.d/rc.M (multi-user runlevel) starts the original /etc/rc.d/rc.inet1
# script that brings up the loopback. It has been patched to start our custom
# script /etc/rc.d/rc.venet. This script can start/stop/restart the venet0
# interface. It executes /etc/rc.d/rc.venet.start on start and
# /etc/rc.d/rc.venet.stop on stop.
#
# These scripts are responsible for configuring the interface and are generated
# by vzctl -- this is where a patch for vzctl is needed. rc.venet.{start,stop}
# scripts configure the interface using /sbin/ip commands (needs package
# iproute2). The contents of these files is rewritten on VPS start and
# on vzctl set --ipadd/ipdel commands.

DISTNAME=slackware
RELVER=14.2
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
coreutils
cpio
dcron
devs
dialog
diffutils
etc
file
findutils
gawk
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
logrotate
man
man-pages
mpfr
nano
net-tools
nettle
network-scripts
openssh
openssl-solibs
pkgtools
procps
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

EXTRA_PKGS="
libmpc
libffi
libtermcap
ncurses
p11-kit
perl
python
readline
"

require_cmd wget

download_repo() {
	local sumdir="$LOCAL_REPO/mirrors.slackware.com/slackware/slackware64-$RELVER/slackware64"

	mkdir -p "$sumdir"
	wget -O - "$BASEURL/slackware64-$RELVER/slackware64/CHECKSUMS.md5" \
		| grep -P '\./(a|ap|l|n)/' \
		| grep -P '\.t.z$' \
		> "$sumdir/CHECKSUMS.md5"
	wget --recursive \
		--level 1 \
		--directory-prefix "$LOCAL_REPO" \
		--accept "*.t?z" \
		"$BASEURL/slackware64-$RELVER/slackware64/"{a,ap,l,n}

	if ! (cd "$sumdir" ; cat CHECKSUMS.md5 | md5sum -c) ; then
		warn "Mirror checksum invalid"
		exit 1
	fi
}

find_pkg() {
	pkg=`find "$DOWNLOAD" -type f -name "$1-*.t?z"`

	if [ "$pkg" == "" ] ; then
		warn "Package '$1' not found"
		exit 1
	fi

	echo $pkg
}

setup_pkgtools() {
	mkdir -p "$LOCAL_ROOT"

	pkg="`find_pkg pkgtools`"
	[ "$?" != "0" ] && exit 1

	tar -xJf "$pkg" -C "$LOCAL_ROOT"
	INSTALLPKG="$LOCAL_ROOT/sbin/installpkg"
}

install_pkg() {
	pkg=`find_pkg $1`
	[ "$?" != "0" ] && exit 1

	$INSTALLPKG --terse --root "$INSTALL" $pkg
}


download_repo || exit 1

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

# Install extra packages
slackpkg -batch=on -default_answer=y install `echo $EXTRA_PKGS | tr '\n' ' '`

# hwclock is not available
sed -i -e '/^if \[ -x \/sbin\/hwclock/,/^fi$/s/^/#/' /etc/rc.d/rc.S
sed -i -e '/^if \[ -x \/sbin\/hwclock/,/^fi$/s/^/#/' /etc/rc.d/rc.6

# Do not test if the rootfs is read-only, as it never is
sed -i -e '/^if touch \/fsrwtestfile/,/^fi$/s/^/#/' /etc/rc.d/rc.S
sed -i -e '/^if \[ ! \$READWRITE = yes/,/^fi # Done checking root filesystem/s/^/#/' /etc/rc.d/rc.S

# Disable setterm
sed -i -e '/^\/bin\/setterm/s/^/#/' /etc/rc.d/rc.M

# /etc/fstab
cat <<END > /etc/fstab
devpts           /dev/pts         devpts      gid=5,mode=620   0   0
tmpfs            /dev/shm         tmpfs       defaults         0   0
END

# Remote console
sed -i -r 's/^(c[3-6]:)/#\1/g' /etc/inittab

# Configure SSH
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Skip fsck
touch /etc/fastboot

# Custom network setup script
sed -i '/^# Start networking daemons:$/i \
# Setup vz network\n\
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

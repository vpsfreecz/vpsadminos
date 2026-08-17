BASEURL=https://mirrors.slackware.com/slackware/
LOCAL_REPO="$DOWNLOAD/repo"
LOCAL_ROOT="$DOWNLOAD/root"
INSTALLPKG=
PKGLIST="$DOWNLOAD/pkglist.txt"
PKGS="
aaa_base
aaa_glibc-solibs
aaa_libraries
aaa_terminfo
acl
attr
bash
bin
bzip2
ca-certificates
coreutils
cpio
cracklib
dcron
devs
dialog
diffutils
dhcpcd
e2fsprogs
elfutils
elogind
etc
eudev
file
findutils
gawk
$SLACKWARE_POWER_PACKAGE_AFTER_GAWK
glibc-zoneinfo
gmp
gnupg
gnutls
gpm
grep
groff
gzip
hostname
iproute2
iputils
keyutils
krb5
less
libcap
libmpc
libffi
libidn2
libmnl
libnsl
libpsl
libpwquality
libseccomp
libsigsegv
libsodium
libtirpc
libunistring
libusb
libusb-compat
logrotate
man
man-pages
mpfr
nano
ncurses
net-tools
nettle
network-scripts
$SLACKWARE_POWER_PACKAGE_AFTER_NETWORK_SCRIPTS
openssh
n/openssl
a/openssl-solibs
pam
p11-kit
pcre
pcre2
perl
pkgtools
procps
python3
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
zlib
"

require_cmd curl

download_index() {
	mkdir -p "$LOCAL_REPO"
	curl -sSL -o "$LOCAL_REPO/FILELIST.txt" $BASEURL/slackware64-$RELVER/FILELIST.TXT
	curl -sSL -o "$LOCAL_REPO/CHECKSUMS.md5" $BASEURL/slackware64-$RELVER/CHECKSUMS.md5
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
	curl -sSL -o "$LOCAL_REPO/$path" $BASEURL/slackware64-$RELVER/$path

	if ! (cd "$LOCAL_REPO" ; grep "$path$" CHECKSUMS.md5 | md5sum -c > /dev/null)
	then
		warn "$1 checksum invalid"
		exit 1
	fi

	echo "$LOCAL_REPO/$path"
}

setup_pkgtools() {
	mkdir -p "$LOCAL_ROOT"

	local pkg="`download_pkg pkgtools`"
	[ "$?" != "0" ] && exit 1

	tar -xJf "$pkg" -C "$LOCAL_ROOT"
	INSTALLPKG="$LOCAL_ROOT/sbin/installpkg"
}

install_pkg() {
	local pkg=`download_pkg $1`
	[ "$?" != "0" ] && exit 1

	$INSTALLPKG --terse --root "$INSTALL" $pkg
}

download_pkg_to_list() {
	local pkg="`download_pkg $1`"
	[ "$?" != "0" ] && exit 1

	flock "$PKGLIST" bash -c "echo $pkg >> \"$PKGLIST\""
}

install_pkg_from_list() {
	$INSTALLPKG --terse --root "$INSTALL" $1
}

slackware-bootstrap() {
	download_index || exit 1

	# Install pkgtools outside the rootfs
	setup_pkgtools || exit 1

	# Download all packages
	export BASEURL LOCAL_REPO PKGLIST RELVER
	export -f download_pkg_to_list download_pkg

	touch "$PKGLIST"

	for pkg in $PKGS ; do
		echo $pkg
	done | xargs -n 1 -P $(nproc) -I {} bash -c 'download_pkg_to_list "$@"' _ {}

	# Install all packages in the rootfs
	for pkg in $(cat "$PKGLIST") ; do
		echo "Installing $pkg"
		install_pkg_from_list $pkg

		if [ "$?" != "0" ] ; then
			warn "Unable to install '$pkg'"
			exit 1
		fi
	done

	cp "$IMAGEDIR"/cgroups.sh "$INSTALL"/etc/rc.d/rc.vpsadminos.cgroups
}

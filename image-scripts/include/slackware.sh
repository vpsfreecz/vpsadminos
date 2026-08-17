BASEURL=https://mirrors.slackware.com/slackware/
LOCAL_REPO="$DOWNLOAD/repo"
LOCAL_ROOT="$DOWNLOAD/root"
PACKAGE_LOOKUP="$LOCAL_REPO/packages.tsv"
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
man-db
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
procps-ng
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

require_cmd awk curl md5sum

download_file() {
	local url="$1"
	local destination="$2"
	local temporary="$destination.part.$$"

	if ! mkdir -p "$(dirname "$destination")" ; then
		warn "Unable to create directory for '$destination'"
		return 1
	fi

	if ! curl \
		--fail \
		--location \
		--silent \
		--show-error \
		--retry 5 \
		--retry-all-errors \
		--connect-timeout 30 \
		--output "$temporary" \
		"$url"
	then
		warn "Unable to download '$url'"
		rm -f "$temporary"
		return 1
	fi

	if ! mv "$temporary" "$destination" ; then
		warn "Unable to move '$temporary' to '$destination'"
		rm -f "$temporary"
		return 1
	fi
}

download_index() {
	mkdir -p "$LOCAL_REPO" || return 1
	download_file \
		"$BASEURL/slackware64-$RELVER/FILELIST.TXT" \
		"$LOCAL_REPO/FILELIST.txt" || return 1
	download_file \
		"$BASEURL/slackware64-$RELVER/CHECKSUMS.md5" \
		"$LOCAL_REPO/CHECKSUMS.md5"
}

build_package_lookup() {
	local temporary="$PACKAGE_LOOKUP.part.$$"

	if ! awk '
		NR == FNR {
			checksum_count[$2]++
			checksum[$2] = $1
			next
		}

		{
			path = $NF

			if (path !~ /^\.\/slackware64\/[^/]+\/[^/]+\.t.z$/) {
				next
			}

			relative = substr(path, length("./slackware64/") + 1)
			separator = index(relative, "/")
			series = substr(relative, 1, separator - 1)
			filename = substr(relative, separator + 1)
			name = filename
			sub(/\.t.z$/, "", name)

			for (i = 0; i < 3; i++) {
				original = name
				sub(/-[^-]+$/, "", name)

				if (name == original) {
					next
				}
			}

			printf "%s\t%s\t%d\t%s\n", \
				name, path, checksum_count[path], checksum[path]
			printf "%s/%s\t%s\t%d\t%s\n", \
				series, name, path, checksum_count[path], checksum[path]
		}
	' \
		"$LOCAL_REPO/CHECKSUMS.md5" \
		"$LOCAL_REPO/FILELIST.txt" \
		> "$temporary"
	then
		warn "Unable to index Slackware package metadata"
		rm -f "$temporary"
		return 1
	fi

	if ! mv "$temporary" "$PACKAGE_LOOKUP" ; then
		warn "Unable to move '$temporary' to '$PACKAGE_LOOKUP'"
		rm -f "$temporary"
		return 1
	fi
}

resolve_pkg() {
	local requested="$1"
	local path checksum_count checksum match
	local -a matches=()

	mapfile -t matches < <(
		awk -F '\t' -v requested="$requested" '
			$1 == requested { print $2 "\t" $3 "\t" $4 }
		' "$PACKAGE_LOOKUP"
	)

	if [ "${#matches[@]}" -eq 0 ] ; then
		warn "Package '$requested' not found"
		return 1
	elif [ "${#matches[@]}" -gt 1 ] ; then
		local paths=()

		for match in "${matches[@]}" ; do
			paths+=("${match%%$'\t'*}")
		done

		warn "Package '$requested' is ambiguous: ${paths[*]}"
		return 1
	fi

	IFS=$'\t' read -r path checksum_count checksum <<< "${matches[0]}"

	if [ "$checksum_count" -ne 1 ] ; then
		warn "Package '$requested' has $checksum_count checksum entries"
		return 1
	fi

	printf '%s\t%s\n' "$path" "$checksum"
}

validate_pkg() {
	local requested="$1"
	local path="$2"
	local checksum="$3"

	if ! (
		cd "$LOCAL_REPO" \
			&& printf '%s  %s\n' "$checksum" "$path" \
				| md5sum --check --status
	) ; then
		warn "Package '$requested' checksum invalid"
		return 1
	fi
}

download_pkg() {
	local requested="$1"
	local metadata path checksum pkg

	metadata=$(resolve_pkg "$requested") || return $?
	IFS=$'\t' read -r path checksum <<< "$metadata"
	pkg="$LOCAL_REPO/${path#./}"

	if [ -f "$pkg" ] ; then
		if validate_pkg "$requested" "$path" "$checksum" ; then
			echo "$pkg"
			return 0
		fi

		warn "Downloading package '$requested' again"
		rm -f "$pkg"
	fi

	download_file \
		"$BASEURL/slackware64-$RELVER/$path" \
		"$pkg" || return 1

	if ! validate_pkg "$requested" "$path" "$checksum" ; then
		rm -f "$pkg"
		return 1
	fi

	echo "$pkg"
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
	build_package_lookup || exit 1

	# Install pkgtools outside the rootfs
	setup_pkgtools || exit 1

	# Download all packages
	export BASEURL LOCAL_REPO PACKAGE_LOOKUP PKGLIST RELVER
	export -f \
		download_file \
		download_pkg \
		download_pkg_to_list \
		resolve_pkg \
		validate_pkg \
		warn

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

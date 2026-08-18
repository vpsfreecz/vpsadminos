#!/usr/bin/env bash

set -eu

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

# shellcheck source=image-scripts/include/common.sh
. "$repo_root/image-scripts/include/common.sh"

mount_call=0
mount_failure=0
mount_status=0
mount_calls=()
make_private_status=0
mkdir_status=0
chroot_calls=0
mock_chroot_status=0
umount_calls=()
mock_umount_status=0

mkdir() {
	return "$mkdir_status"
}

mount() {
	mount_call=$((mount_call + 1))
	mount_calls+=("$*")

	if [ "$mount_call" -eq "$mount_failure" ] ; then
		return "$mount_status"
	fi
	if [ "$1" = "--make-rprivate" ] && [ "$make_private_status" -ne 0 ] ; then
		return "$make_private_status"
	fi

	return 0
}

chroot() {
	chroot_calls=$((chroot_calls + 1))
	return "$mock_chroot_status"
}

umount() {
	umount_calls+=("$*")
	return "$mock_umount_status"
}

mkdir_status=29
set +e
do-chroot /target /configure
status=$?
set -e

if [ "$status" -ne 29 ] || [ "$mount_call" -ne 0 ] \
		|| [ "$chroot_calls" -ne 0 ] || [ "${#umount_calls[@]}" -ne 0 ] ; then
	echo "mkdir failure was not preserved" >&2
	exit 1
fi

mkdir_status=0
mock_umount_status=71

for mount_failure in 1 2 3 4 ; do
	mount_call=0
	mount_status=$((30 + mount_failure))
	mount_calls=()
	chroot_calls=0
	umount_calls=()
	expected_cleanup=

	set +e
	do-chroot /target /configure
	status=$?
	set -e

	if [ "$status" -ne "$mount_status" ] ; then
		echo "mount $mount_failure returned $status, expected $mount_status" >&2
		exit 1
	fi

	if [ "$chroot_calls" -ne 0 ] ; then
		echo "chroot ran after mount $mount_failure failed" >&2
		exit 1
	fi

	case "$mount_failure" in
	1)
		expected_cleanup=
		;;
	2)
		expected_cleanup=/target/proc
		;;
	3)
		expected_cleanup="/target/sys /target/proc"
		;;
	4)
		expected_cleanup="-R /target/dev /target/sys /target/proc"
		if [ "${mount_calls[4]}" != "--make-rprivate /target/dev" ] ; then
			echo "shared /dev clone was not made private before cleanup" >&2
			exit 1
		fi
		;;
	esac

	if [ "${umount_calls[*]}" != "$expected_cleanup" ] ; then
		echo "partial mount cleanup was not attempted completely" >&2
		exit 1
	fi
done

mount_failure=4
mount_call=0
mount_status=34
mount_calls=()
make_private_status=72
chroot_calls=0
umount_calls=()

set +e
do-chroot /target /configure
status=$?
set -e

if [ "$status" -ne 34 ] || [ "$chroot_calls" -ne 0 ] ; then
	echo "make-rslave failure was not preserved" >&2
	exit 1
fi

if [ "${mount_calls[4]}" != "--make-rprivate /target/dev" ] \
		|| [ "${umount_calls[*]}" != "/target/sys /target/proc" ] ; then
	echo "shared /dev clone was recursively unmounted without a private barrier" >&2
	exit 1
fi

mount_failure=0
mount_call=0
make_private_status=0
mock_chroot_status=41
chroot_calls=0
umount_calls=()

set +e
do-chroot /target /configure
status=$?
set -e

if [ "$status" -ne 41 ] || [ "$chroot_calls" -ne 1 ] ; then
	echo "chroot failure was not preserved" >&2
	exit 1
fi

mock_chroot_status=0
chroot_calls=0
umount_calls=()

set +e
do-chroot /target /configure
status=$?
set -e

if [ "$status" -ne 71 ] || [ "$chroot_calls" -ne 1 ] ; then
	echo "cleanup failure was not propagated" >&2
	exit 1
fi

require_cmd() {
	return 0
}

SPIN=leap
SPINVER=15.6
INSTALL=/target
INCLUDE="$repo_root/image-scripts/include"

# shellcheck source=image-scripts/include/opensuse.sh
. "$repo_root/image-scripts/include/opensuse.sh"

mock_zypper_status=0
zypper() {
	echo zypper-called

	if [ "$mock_zypper_status" -ne 0 ] ; then
		local status="$mock_zypper_status"
		mock_zypper_status=0
		return "$status"
	fi

	return 0
}

mount_failure=1
mount_call=0
mount_status=47
mock_umount_status=0

set +e
output=$(bootstrap)
status=$?
set -e

if [ "$status" -ne 47 ] || [ -n "$output" ] ; then
	echo "OpenSUSE bootstrap ignored a mount failure" >&2
	exit 1
fi

mount_failure=0
mount_call=0
mock_zypper_status=48
mock_umount_status=71

set +e
output=$(bootstrap)
status=$?
set -e

if [ "$status" -ne 48 ] || [ "$output" != zypper-called ] ; then
	echo "OpenSUSE bootstrap did not prefer its primary failure" >&2
	exit 1
fi

mock_zypper_status=0

set +e
(bootstrap) >/dev/null
status=$?
set -e

if [ "$status" -ne 71 ] ; then
	echo "OpenSUSE bootstrap ignored a cleanup failure" >&2
	exit 1
fi

namespace_fixture=$(mktemp -d /tmp/vpsadminos-image-namespace.XXXXXXXX)
namespace_record="$namespace_fixture/unshare.args"

command cat > "$namespace_fixture/unshare" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$VPSADMINOS_IMAGE_NAMESPACE_RECORD"
exit 47
EOF
command chmod +x "$namespace_fixture/unshare"

set +e
PATH="$namespace_fixture:$PATH" \
	VPSADMINOS_IMAGE_NAMESPACE_RECORD="$namespace_record" \
	"$repo_root/image-scripts/bin/runner" image build >/dev/null 2>&1
status=$?
set -e

expected_namespace_args=$(cat <<EOF
--mount
--propagation
private
--
env
VPSADMINOS_IMAGE_MOUNT_NAMESPACE=1
$repo_root/image-scripts/bin/runner
image
build
EOF
)

if [ "$status" -ne 47 ] \
		|| [ "$(command cat "$namespace_record")" != "$expected_namespace_args" ] ; then
	echo "image runner did not enter a private mount namespace" >&2
	exit 1
fi

command rm -f "$namespace_record"

set +e
PATH="$namespace_fixture:$PATH" \
	VPSADMINOS_IMAGE_NAMESPACE_RECORD="$namespace_record" \
	VPSADMINOS_IMAGE_MOUNT_NAMESPACE=1 \
	"$repo_root/image-scripts/bin/runner" image build >/dev/null 2>&1
status=$?
set -e

if [ "$status" -ne 1 ] || [ -e "$namespace_record" ] ; then
	echo "image runner recursively entered its mount namespace" >&2
	exit 1
fi

find "$namespace_fixture" -depth -delete

fixture=$(mktemp -d /tmp/vpsadminos-arch-bootstrap.XXXXXXXX)
command mkdir -p \
	"$fixture/download" \
	"$fixture/install/root.x86_64/etc/pacman.d" \
	"$fixture/install/root.x86_64/bin"

set +e
output=$(
	IMAGEDIR="$repo_root/image-scripts/images/arch"
	INCLUDE="$repo_root/image-scripts/include"
	DOWNLOAD="$fixture/download"
	INSTALL="$fixture/install"

	curl() { return 0; }
	grep() { echo archlinux-bootstrap-2026.08.01-x86_64.tar.zst; }
	tar() { return 0; }
	sed() { return 0; }
	# shellcheck disable=SC2329
	printf() { return 0; }
	patch() { return 0; }
	cat() { return 0; }
	chmod() { return 0; }
	sha256sum() { return 0; }
	do-chroot() { return 47; }
	configure-append() { return 0; }
	run-configure() { echo run-configure-called; return 0; }
	mv() { echo mv-called; return 0; }
	rm() { echo rm-called; return 0; }

	# shellcheck source=image-scripts/images/arch/build.sh
	. "$repo_root/image-scripts/images/arch/build.sh"
)
status=$?
set -e

find "$fixture" -depth -delete

if [ "$status" -ne 47 ] || [ -n "$output" ] ; then
	echo "Arch bootstrap ignored a chroot failure" >&2
	exit 1
fi

if command -v unshare >/dev/null \
		&& unshare --user --map-root-user --mount true 2>/dev/null ; then
unshare --user --map-root-user --mount --propagation private bash -eu <<'EOF'
root=$(mktemp -d /tmp/vpsadminos-mount-propagation.XXXXXXXX)

cleanup() {
	if mountpoint -q "$root/clone" ; then
		umount -R "$root/clone" || true
	fi
	if mountpoint -q "$root/source" ; then
		umount -R "$root/source" || true
	fi
	rmdir "$root/clone" "$root/source/child" "$root/source" "$root" 2>/dev/null || true
}
trap cleanup EXIT

mkdir "$root/source" "$root/clone"
mount -t tmpfs tmpfs "$root/source"
mkdir "$root/source/child"
mount -t tmpfs tmpfs "$root/source/child"
mount --make-rshared "$root/source"
mount --rbind "$root/source" "$root/clone"
mount --make-rprivate "$root/clone"
umount -R "$root/clone"

mountpoint -q "$root/source/child"
EOF

	namespace_mount=$(mktemp -d /tmp/vpsadminos-mount-namespace.XXXXXXXX)
	unshare --user --map-root-user --mount --propagation private \
		mount -t tmpfs tmpfs "$namespace_mount"

	if mountpoint -q "$namespace_mount" ; then
		echo "mount escaped the disposable namespace" >&2
		exit 1
	fi

	rmdir "$namespace_mount"
fi

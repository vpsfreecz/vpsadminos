set -e
apt-get update
apt-get -y install guix
. /etc/profile.d/guix.sh || true

# This is a workaround for guix pull failing with:
#
#   guix pull: error: while setting up the build environment: mounting /dev/pts: Permission denied
#
# Mounting of /dev/pts can be avoided if /dev/pts/ptmx does not exist.
if [ -e /dev/pts/ptmx ] ; then
	mkdir -p /var/empty
	mount --bind /var/empty /dev/pts
fi

guix pull

. "$IMAGEDIR/config.sh"

. /etc/profile.d/guix.sh

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
hash guix

GUILE_LOAD_PATH="$IMAGEDIR" guix system init --no-bootloader "$IMAGEDIR"/system.scm "$INSTALL"

mkdir "$INSTALL"/etc/config "$INSTALL"/sbin

cp "$IMAGEDIR"/system.scm "$INSTALL"/etc/config/system.scm
cp "$IMAGEDIR"/vpsadminos.scm "$INSTALL"/etc/config/vpsadminos.scm
chmod u+w "$INSTALL"/etc/config/system.scm "$INSTALL"/etc/config/vpsadminos.scm

cp "$IMAGEDIR"/sbin-init.scm "$INSTALL"/sbin/init
chmod +x "$INSTALL"/sbin/init

. "$IMAGEDIR/config.sh"

. /etc/profile.d/guix.sh

guix pull

GUILE_LOAD_PATH="$IMAGEDIR" guix system init --no-bootloader "$IMAGEDIR"/system.scm "$INSTALL"

mkdir "$INSTALL"/etc/config "$INSTALL"/sbin

cp "$IMAGEDIR"/system.scm "$INSTALL"/etc/config/system.scm
cp "$IMAGEDIR"/vpsadminos.scm "$INSTALL"/etc/config/vpsadminos.scm
chmod u+w "$INSTALL"/etc/config/system.scm "$INSTALL"/etc/config/vpsadminos.scm

cp "$IMAGEDIR"/sbin-init.scm "$INSTALL"/sbin/init
chmod +x "$INSTALL"/sbin/init

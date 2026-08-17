. "$IMAGEDIR/config.sh"

. /etc/profile.d/guix.sh

set -e

for attempt in 1 2 3; do
	if guix pull -C "$IMAGEDIR/channels.scm"; then
		break
	elif [ "$attempt" -eq 3 ]; then
		exit 1
	fi

	sleep 30
done
hash guix

guix system init --verbosity=3 -L "$IMAGEDIR" "$IMAGEDIR"/system.scm "$INSTALL"

mkdir "$INSTALL"/etc/config "$INSTALL"/sbin

cp "$IMAGEDIR"/system.scm "$INSTALL"/etc/config/system.scm
cp "$IMAGEDIR"/vpsadminos.scm "$INSTALL"/etc/config/vpsadminos.scm
cp "$IMAGEDIR"/channels.scm "$INSTALL"/etc/config/channels.scm
chmod u+w \
	"$INSTALL"/etc/config/system.scm \
	"$INSTALL"/etc/config/vpsadminos.scm \
	"$INSTALL"/etc/config/channels.scm

cp "$IMAGEDIR"/sbin-init.scm "$INSTALL"/sbin/init
chmod +x "$INSTALL"/sbin/init

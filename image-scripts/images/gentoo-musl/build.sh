VARIANT=musl
. "$IMAGEDIR/config.sh"
. "$INCLUDE/gentoo.sh"

fetch
extract
configure-gentoo-begin

configure-append <<EOF
sed -ri 's/^#rc_sys=""/rc_sys="lxc"/' /etc/rc.conf
sed -ri 's/^([^#].*agetty.*)$/#\1/' /etc/inittab

rc-update add sshd default

cat >> /etc/inittab <<END

# Start getty on /dev/console
c0:2345:respawn:/sbin/agetty 38400 console linux

# Clean container shutdown on SIGPWR
pf:12345:powerwait:/sbin/halt
END
EOF

configure-gentoo-end
run-configure

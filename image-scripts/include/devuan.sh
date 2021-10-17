require_cmd debootstrap

CONFIGURE_DEVUAN="$CONFIGURE.devuan"

function bootstrap {
	mkdir $INSTALL/etc
	echo nameserver 8.8.8.8 > $INSTALL/etc/resolv.conf
	debootstrap --include locales --arch amd64 $RELNAME $INSTALL $BASEURL
}

function configure-devuan-append {
	cat >> "$CONFIGURE_DEVUAN"
}

function configure-devuan {
	configure-shebang "#!/bin/bash"
	configure-append <<EOF
fakefiles="initctl invoke-rc.d restart start stop start-stop-daemon service"
for f in \$fakefiles; do
	ln -s /bin/true /tmp/\$f
done
export DEBIAN_FRONTEND=noninteractive;

[ -f /etc/locale.gen ] && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen

locale-gen en_US.UTF-8
dpkg-reconfigure locales

# dpkg-reconfigure locales will not se the default system locale by itself
echo LANG=en_US.UTF-8 >> /etc/default/locale

PATH=/tmp/:\$PATH apt-get update
PATH=/tmp/:\$PATH apt-get upgrade -y
PATH=/tmp/:\$PATH apt-get install -y vim openssh-server ca-certificates man net-tools ifupdown less cgroup-tools
PATH=/tmp/:\$PATH apt-get install -y --force-yes devuan-keyring

# for snapd
PATH=/tmp/:\$PATH apt-get install -y fuse squashfuse
mkdir /lib/modules

for pkg in ureadahead eject ntpdate resolvconf ; do
	PATH=/tmp/:\$PATH apt-get purge -y $pkg
done
usermod -L root
rm -f /etc/ssh/ssh_host_*

cat > /etc/init.d/generate_ssh_keys <<"GENSSH"
#!/bin/sh

### BEGIN INIT INFO
# Provides:           host-ssh-keys
# Required-Start:     \$local_fs
# Required-Stop:      \$local_fs
# Default-Start:      S
# Default-Stop:
# Short-Description:  Generate SSH host keys on first boot.
### END INIT INFO

. /lib/lsb/init-functions

set -e

case "\$1" in
	start)
		log_begin_msg 'Generating SSH host keys'
		ssh-keygen -q -f /etc/ssh/ssh_host_rsa_key -t rsa -N ''
		ssh-keygen -q -f /etc/ssh/ssh_host_dsa_key -t dsa -N ''
		ssh-keygen -q -f /etc/ssh/ssh_host_ecdsa_key -t ecdsa -N ''
		ssh-keygen -q -f /etc/ssh/ssh_host_ed25519_key -t ed25519 -N ''
		update-rc.d generate_ssh_keys remove
		rm -f /etc/init.d/generate_ssh_keys
		log_end_msg \$?
		;;
	*)
		log_failure_msg "operation '\$2' not supported"
		exit 1
		;;
esac

exit 0
GENSSH

chmod a+x /etc/init.d/generate_ssh_keys
update-rc.d generate_ssh_keys defaults

sed -i 's|pf::powerwait:/etc/init.d/powerfail start|pf::powerwait:/sbin/halt|' /etc/inittab
sed -ri 's/^([^#].*getty.*)$/#\1/' /etc/inittab

cat >> /etc/inittab <<END

# Start getty on /dev/console
c0:2345:respawn:/sbin/agetty --noreset 38400 console
END

sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

$([ -f "$CONFIGURE_DEVUAN" ] && cat "$CONFIGURE_DEVUAN")

> /etc/resolv.conf
rm -f /etc/hostname

apt-get clean
for f in \$fakefiles; do
	rm -f /tmp/\$f
done
EOF
}

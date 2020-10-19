require_cmd debootstrap

CONFIGURE_DEBIAN="$CONFIGURE.debian"

function bootstrap {
	mkdir $INSTALL/etc
	echo nameserver 8.8.8.8 > $INSTALL/etc/resolv.conf
	debootstrap --include locales --arch amd64 $RELNAME $INSTALL $BASEURL
}

function configure-debian-append {
	cat >> "$CONFIGURE_DEBIAN"
}

function configure-debian {
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
PATH=/tmp/:\$PATH apt-get install -y vim openssh-server ca-certificates man net-tools ifupdown less

# for snapd
PATH=/tmp/:\$PATH apt-get install -y fuse squashfuse
mkdir /lib/modules

for pkg in ureadahead eject ntpdate resolvconf ; do
	PATH=/tmp/:\$PATH apt-get purge -y $pkg
done
usermod -L root
rm -f /etc/ssh/ssh_host_*

if [ -f /etc/systemd/system.conf ] ; then

cat > /etc/systemd/system/sshd-keygen.service <<"KEYGENSVC"
[Unit]
Description=OpenSSH Server Key Generation
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
KEYGENSVC

ln -s /etc/systemd/system/sshd-keygen.service /etc/systemd/system/multi-user.target.wants/sshd-keygen.service

else

cat > /etc/init.d/generate_ssh_keys <<"GENSSH"
#!/bin/sh

### BEGIN INIT INFO
# Provides:           host-ssh-keys
# Required-Start:     \$local_fs \$remote_fs
# Required-Stop:      \$local_fs \$remote_fs
# Default-Start:      2 3 4 5
# Default-Stop:       0 1 6
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
		rm -f /etc/init.d/generate_ssh_keys
		update-rc.d generate_ssh_keys remove
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

fi

$([ -f "$CONFIGURE_DEBIAN" ] && cat "$CONFIGURE_DEBIAN")

> /etc/resolv.conf
rm -f /etc/hostname

apt-get clean
for f in \$fakefiles; do
	rm -f /tmp/\$f
done

if [ -f /etc/systemd/system.conf ] ; then
	sed -i 's/#DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=900s/' /etc/systemd/system.conf
fi

[ -d /etc/systemd ] && mkdir -p /var/log/journal

systemctl mask journald-audit.socket
systemctl mask systemd-udev-trigger.service
EOF
}

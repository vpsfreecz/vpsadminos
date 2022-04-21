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

cat > /etc/systemd/system/sshd-keygen.service <<"KEYGENSVC"
[Unit]
Description=OpenSSH Server Key Generation
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
KEYGENSVC

ln -s /etc/systemd/system/sshd-keygen.service /etc/systemd/system/multi-user.target.wants/sshd-keygen.service

$([ -f "$CONFIGURE_DEBIAN" ] && cat "$CONFIGURE_DEBIAN")

> /etc/resolv.conf
rm -f /etc/hostname

apt-get clean
for f in \$fakefiles; do
	rm -f /tmp/\$f
done

sed -i 's/#DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=900s/' /etc/systemd/system.conf

mkdir -p /var/log/journal

systemctl mask journald-audit.socket
systemctl mask systemd-journald-audit.socket
systemctl mask systemd-udev-trigger.service
systemctl mask sys-kernel-debug.mount
EOF
}

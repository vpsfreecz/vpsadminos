function bootstrap {
	debootstrap --arch amd64 $RELNAME $INSTALL $BASEURL
}

function configure-debian {
	configure-append <<EOF
fakefiles="initctl invoke-rc.d restart start stop start-stop-daemon service"
for f in \$fakefiles; do
	ln -s /bin/true /tmp/\$f
done
export DEBIAN_FRONTEND=noninteractive;
PATH=/tmp/:\$PATH apt-get update
PATH=/tmp/:\$PATH apt-get install -y locales

locale-gen en_US.UTF-8

dpkg-reconfigure locales

PATH=/tmp/:\$PATH apt-get upgrade -y
PATH=/tmp/:\$PATH apt-get purge -y ureadahead eject ntpdate resolvconf
PATH=/tmp/:\$PATH apt-get install -y vim openssh-server
usermod -L root

cp /usr/share/zoneinfo/Europe/Prague /etc/localtime

rm -f /etc/ssh/ssh_host_*

cat > /etc/init.d/generate_ssh_keys <<"GENSSH"
#!/bin/bash
ssh-keygen -f /etc/ssh/ssh_host_rsa_key -t rsa -N ''
ssh-keygen -f /etc/ssh/ssh_host_dsa_key -t dsa -N ''
rm -f /etc/init.d/generate_ssh_keys
GENSSH

chmod a+x /etc/init.d/generate_ssh_keys
update-rc.d generate_ssh_keys defaults

> /etc/resolv.conf

apt-cache clean
for f in \$fakefiles; do
	rm -f /tmp/\$f
done
EOF
}

function bootstrap {
	debootstrap --arch amd64 $RELNAME $INSTALL $BASEURL
}

function configure-debian {
	configure-append <<EOF
locale-gen en_US.UTF-8

dpkg-reconfigure locales

usermod -L root

apt-get update
apt-get upgrade -y
export DEBIAN_FRONTEND=noninteractive; apt-get purge -y ureadahead eject ntpdate resolvconf
apt-get install -y vim openssh-server

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

apt-get clean
EOF
}

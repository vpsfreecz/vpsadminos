DISTNAME=debian
RELVER=9
RELNAME=strech
BASEURL=http://ftp.cz.debian.org/debian

. $INCLUDE/debian.sh

bootstrap

configure-common
configure-debian

cat > $INSTALL/etc/apt/sources.list <<SOURCES
deb $BASEURL $RELNAME main
deb-src $BASEURL $RELNAME main

deb $BASEURL $RELNAME-updates main
deb-src $BASEURL $RELNAME-updates main

deb http://security.debian.org/ $RELNAME/updates main
deb-src http://security.debian.org/ $RELNAME/updates main
SOURCES

configure-append <<EOF
sed -i -e '/^PermitRootLogin/ s/^#*/#/' /etc/ssh/sshd_config
ln -s /dev/null /etc/systemd/system/proc-sys-fs-binfmt_misc.automount

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
EOF

run-configure

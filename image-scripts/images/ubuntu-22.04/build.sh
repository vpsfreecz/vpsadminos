. "$IMAGEDIR/config.sh"
RELNAME=jammy
BASEURL=http://cz.archive.ubuntu.com/ubuntu/

. $INCLUDE/debian.sh

bootstrap
configure-common

cat > $INSTALL/etc/apt/sources.list <<SOURCES
deb $BASEURL $RELNAME main restricted universe multiverse
deb $BASEURL $RELNAME-security main restricted universe multiverse
deb $BASEURL $RELNAME-updates main restricted universe multiverse
SOURCES

configure-debian-append <<EOF
sed -i -e 's/^\\\$ModLoad imklog/#\\\$ModLoad imklog/g' /etc/rsyslog.conf
sed -i -e 's/^#PermitRootLogin\ prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config
rm -f /etc/resolv.conf

# On the first start, wait for the ssh host keys to be generated before starting
# sshd
mkdir -p /etc/systemd/system/ssh.service.d
cat <<EOT > /etc/systemd/system/ssh.service.d/vpsadminos.conf
[Unit]
After=sshd-keygen.service
EOT
EOF

configure-debian

run-configure

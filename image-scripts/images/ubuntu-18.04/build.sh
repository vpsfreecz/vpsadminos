. "$IMAGEDIR/config.sh"
RELNAME=bionic
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
# For some reason, dpkg isn't configured correctly, mainly
# /sbin/start-stop-daemon is not set up properly -- there's just a fake script
# instead of the real program. It may have something to do with rsyslog
# configuration failing with debootstrap:
#
#  Setting up rsyslog (8.32.0-1ubuntu4) ...
#  The user 'syslog' is already a member of 'adm'.
#  chmod() of /var/spool/rsyslog via /proc/self/fd/3 failed: No such file or directory
#  chmod() of /var/log via /proc/self/fd/3 failed: No such file or directory
#  dpkg: error processing package rsyslog (--configure):
#   installed rsyslog package post-installation script subprocess returned error exit status 1
#  Errors were encountered while processing:
#   rsyslog
#
apt-get install -y --reinstall dpkg

sed -i -e 's/^\\\$ModLoad imklog/#\\\$ModLoad imklog/g' /etc/rsyslog.conf
sed -i -e 's/^#PermitRootLogin\ prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config
rm -f /etc/resolv.conf
EOF

configure-debian

run-configure

#!/bin/bash

. $BASEDIR/include/common

YUM="yum -c $DOWNLOAD/yum.conf --installroot=$INSTALL --disablerepo=* --enablerepo=install-$DISTNAME --enablerepo=install-$DISTNAME-updates -y"

function bootstrap {
	mkdir -p ${INSTALL}/var/lib/rpm
	rpm --root $INSTALL --initdb

	curl -o $DOWNLOAD/release.rpm $RELEASE

	rpm --root $INSTALL --nodeps -ivh $DOWNLOAD/release.rpm

	cat > $DOWNLOAD/yum.conf << EOF
[main]
cachedir=$DOWNLOAD/var/cache/yum/\$basearch/\$releasever
keepcache=0
debuglevel=2
logfile=$DOWNLOAD/var/log/yum.log
exactarch=1
obsoletes=1
gpgcheck=1
plugins=1
installonly_limit=3

[install-$DISTNAME]
name=install-$DISTNAME
enabled=1
gpgcheck=0
baseurl=$BASEURL

[install-$DISTNAME-updates]
name=install-$DISTNAME-updates
enabled=1
gpgcheck=0
baseurl=$UPDATES
EOF

	mkdir -p $DOWNLOAD/var/cache/yum
	mkdir -p $DOWNLOAD/var/log


	$YUM groupinstall "$GROUPNAME"
	$YUM install "$EXTRAPKGS"
	$YUM clean all

}

function configure-fedora {
	configure-append <<EOF
usermod -L root
rm -f /etc/ssh/ssh_host_*
EOF
}

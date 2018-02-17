#!/bin/bash

. $BASEDIR/include/common.sh

if [ "$DISTNAME" == "fedora" ] && [ "$RELVER" -ge 22 ]; then
	require_cmd dnf

	YUM="dnf -c $DOWNLOAD/yum.conf --installroot=$INSTALL \
		--disablerepo=* --enablerepo=install-$DISTNAME \
		--enablerepo=install-$DISTNAME-updates -y"
	YUM_GROUPINSTALL="$YUM group install"
else
	require_cmd yum

	YUM="yum -c $DOWNLOAD/yum.conf --installroot=$INSTALL \
		--disablerepo=* --enablerepo=install-$DISTNAME \
		--enablerepo=install-$DISTNAME-updates -y"
	YUM_GROUPINSTALL="$YUM groupinstall"
fi

function bootstrap {
	mkdir -p ${INSTALL}/var/lib/rpm
	rpm --root $INSTALL --initdb

	nrpm=0
	for rpm in $RELEASE; do
		nrpm=$(( $nrpm + 1 ))
		echo "Downloading #${nrpm} $rpm"
		curl -o $DOWNLOAD/release${nrpm}.rpm $rpm
		rpm --root $INSTALL --nodeps -ivh $DOWNLOAD/release${nrpm}.rpm
	done

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

	$YUM_GROUPINSTALL "$GROUPNAME"
	for rpm in $EXTRAPKGS; do
		$YUM install $rpm
	done

	for rpm in $REMOVEPKGS; do
		$YUM erase $rpm
	done
	$YUM clean all

}

function configure-redhat-common {
	configure-append <<EOF
usermod -L root
rm -f /etc/ssh/ssh_host_*

if [ -f /etc/systemd/system.conf ] ; then
	sed -i 's/#DefaultTimeoutStartSec=90s/DefaultTimeoutStartSec=900s/' /etc/systemd/system.conf
fi

EOF
}

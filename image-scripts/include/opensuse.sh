#!/bin/bash

. $BASEDIR/include/common.sh

REPOSITORY=http://download.opensuse.org/distribution/$RELVER/repo/oss
UPDATES=http://download.opensuse.org/update/$RELVER/
EXTRAPKGS='vim'

ZYPPER="zypper -v --root=$INSTALL --non-interactive --no-gpg-checks "

function bootstrap {

        $ZYPPER addrepo --refresh $REPOSITORY openSUSE-oss
        $ZYPPER addrepo --refresh $UPDATES openSUSE-updates
        $ZYPPER install openSUSE-release 
        $ZYPPER install -t pattern base sw_management
        $ZYPPER install $EXTRAPKGS
	
}

function configure-opensuse {
	configure-append <<EOF
systemctl disable NetworkManager.service
systemctl disable NetworkManager-wait-online.service
systemctl disable NetworkManager-dispatcher.service
systemctl enable  network.service
usermod -L root
systemctl enable sshd
EOF
}

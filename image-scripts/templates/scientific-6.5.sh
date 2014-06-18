DISTNAME=scientific
RELVER=6.5
RELEASE=http://mirror.vpsfree.cz/scientific/6.5/x86_64/os/Packages/sl-release-6.5-1.x86_64.rpm
BASEURL=http://mirror.vpsfree.cz/scientific/6.5/x86_64/os
UPDATES=http://mirror.vpsfree.cz/scientific/6.5/x86_64/updates/security
GROUPNAME='base'
EXTRAPKGS='vim'

. $INCLUDE/fedora.sh

bootstrap
configure-common

configure-fedora

run-configure

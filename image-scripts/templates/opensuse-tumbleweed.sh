DISTNAME=suse-tumbleweed
RELVER=$(date +%Y%m%d)

. $INCLUDE/opensuse.sh

bootstrap
configure-common

configure-opensuse

run-configure

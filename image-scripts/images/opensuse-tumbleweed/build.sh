. "$IMAGEDIR/config.sh"
. "$INCLUDE/opensuse.sh"

bootstrap
configure-common

configure-opensuse

run-configure
set-initcmd "/sbin/init" "systemd.unified_cgroup_hierarchy=0"

function check_package_list {
	local ret=`osctl ct exec -r $CTID $@`
	[ "$?" != 0 ] && fail "unable to get package list"
	[ "$ret" == "" ] && fail "empty package list"
	return 0
}

case "$DISTNAME" in
	almalinux|centos|fedora|rocky)
		check_package_list rpm -qa
		;;
	alpine)
		check_package_list apk list --installed
		;;
	arch)
		check_package_list pacman -Q
		;;
	debian|devuan|ubuntu)
		check_package_list dpkg-query --list
		;;
	opensuse)
		check_package_list rpm -qa
		;;
	void)
		check_package_list xbps-query -l
		;;
	*)
		echo "No package test for ${DISTNAME}-${RELVER}"
		;;
esac

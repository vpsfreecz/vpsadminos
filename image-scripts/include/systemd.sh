function configure-systemd-console-getty {
	configure-append <<'EOF'
systemdVersion=$(systemctl --version | grep -oP '^systemd \d+ ' | grep -oP '\d+')

if [ "$systemdVersion" -ge 258 ] ; then
	# Fixup console-getty
	# https://github.com/systemd/systemd/issues/39036)
	# https://github.com/lxc/incus/pull/2554
	mkdir -p /etc/systemd/system/console-getty.service.d
	cat <<EOT > /etc/systemd/system/console-getty.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noreset --noclear --issue-file=/etc/issue:/etc/issue.d:/run/issue.d:/usr/lib/issue.d --keep-baud console 115200,57600,38400,9600 ${TERM}
StandardInput=null
StandardOutput=null
EOT
fi

EOF
}

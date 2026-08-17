VARIANT=musl-systemd
. "$IMAGEDIR/config.sh"
. "$INCLUDE/gentoo.sh"
. "$INCLUDE/systemd.sh"

fetch
extract
configure-gentoo-begin

configure-append <<EOF
systemctl enable sshd.service
systemctl enable systemd-networkd.service
systemctl mask systemd-journald-audit.socket

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat <<EOT > /etc/systemd/system/systemd-udev-trigger.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-udevadm trigger --subsystem-match=net --action=add
EOT

echo > /etc/machine-id
EOF

configure-systemd-console-getty
configure-gentoo-remove-rust
configure-gentoo-end
run-configure

. "$IMAGEDIR/config.sh"
BASEURL=http://ftp.fi.muni.cz/pub/linux/fedora/linux/releases/$RELVER/Everything/x86_64/os
RELEASE="$BASEURL/Packages/f/fedora-release-server-$RELVER-25.noarch.rpm
$BASEURL/Packages/f/fedora-release-$RELVER-25.noarch.rpm
$BASEURL/Packages/f/fedora-release-common-$RELVER-25.noarch.rpm
$BASEURL/Packages/f/fedora-release-identity-basic-$RELVER-25.noarch.rpm"
EXTRAPKGS="@core vim man fedora-gpg-keys fedora-repos glibc-langpack-en"
REMOVEPKGS="plymouth"

. $INCLUDE/redhat-family.sh

bootstrap
configure-common

configure-redhat-common
configure-fedora
configure-fedora-nm-keyfiles

configure-append <<'EOF'
systemctl mask systemd-hostnamed.service

# Fixup console-getty
# https://github.com/systemd/systemd/issues/39036
# https://github.com/lxc/incus/pull/2554
mkdir -p /etc/systemd/system/console-getty.service.d
cat <<EOT > /etc/systemd/system/console-getty.service.d/vpsadminos.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noreset --noclear --issue-file=/etc/issue:/etc/issue.d:/run/issue.d:/usr/lib/issue.d --keep-baud console 115200,57600,38400,9600 ${TERM}
StandardInput=null
StandardOutput=null
EOT
EOF

run-configure


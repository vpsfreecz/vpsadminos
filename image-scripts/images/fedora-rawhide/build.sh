. "$IMAGEDIR/config.sh"
RAWHIDE_RELVER=46-0.1
BASEURL=http://ftp.fi.muni.cz/pub/linux/fedora/linux/development/rawhide/Everything/x86_64/os
RELEASE="$BASEURL/Packages/f/fedora-release-server-$RAWHIDE_RELVER.noarch.rpm
$BASEURL/Packages/f/fedora-release-$RAWHIDE_RELVER.noarch.rpm
$BASEURL/Packages/f/fedora-release-common-$RAWHIDE_RELVER.noarch.rpm
$BASEURL/Packages/f/fedora-release-identity-basic-$RAWHIDE_RELVER.noarch.rpm"
EXTRAPKGS="@core vim man fedora-gpg-keys fedora-repos glibc-langpack-en"
REMOVEPKGS="plymouth"

. $INCLUDE/redhat-family.sh
. "$INCLUDE/systemd.sh"

bootstrap
configure-common

configure-redhat-common
configure-fedora
configure-fedora-nm-keyfiles

configure-append <<'EOF'
systemctl mask systemd-hostnamed.service
systemctl mask kmscon.service
systemctl mask kmsconvt@.service

# Rawhide defaults to socket-activated sshd. The shared Fedora setup enables
# sshd.service, so undo that here and keep rawhide on its packaged default.
systemctl disable sshd.service
systemctl enable sshd.socket

# Rawhide's sshd-keygen.target wants the host-key units, but does not wait for
# them before sshd starts.
mkdir -p /etc/systemd/system/sshd-keygen.target.d
cat <<EOT > /etc/systemd/system/sshd-keygen.target.d/vpsadminos.conf
[Unit]
After=sshd-keygen@rsa.service sshd-keygen@ecdsa.service sshd-keygen@ed25519.service
EOT
EOF

configure-systemd-console-getty
run-configure

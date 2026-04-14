. "$IMAGEDIR/config.sh"
RELNAME=testing
BASEURL=http://ftp.cz.debian.org/debian

. "$INCLUDE/debian.sh"
. "$INCLUDE/systemd.sh"

bootstrap

configure-common
configure-debian

cat > "$INSTALL/etc/apt/sources.list" <<SOURCES
deb $BASEURL $RELNAME main
deb-src $BASEURL $RELNAME main

deb $BASEURL $RELNAME-updates main
deb-src $BASEURL $RELNAME-updates main

deb http://security.debian.org/debian-security/ $RELNAME-security main
deb-src http://security.debian.org/debian-security/ $RELNAME-security main
SOURCES

configure-append <<'EOF'
# openssh-server 10.x on Debian testing can leave sshd_config as a sparse
# zero-filled file in the image build, so replace it with a sane text config.
cat > /etc/ssh/sshd_config <<'SSHD_CONFIG'
Include /etc/ssh/sshd_config.d/*.conf
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_* COLORTERM NO_COLOR
Subsystem sftp /usr/lib/openssh/sftp-server
PasswordAuthentication yes
PermitRootLogin yes
SSHD_CONFIG
EOF

configure-systemd-console-getty

run-configure

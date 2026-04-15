set -e
cat > /etc/apt/sources.list.d/guix-unstable.list <<EOF
deb http://ftp.cz.debian.org/debian unstable main
EOF

apt-get update
apt-get -y -t unstable install guix

. /etc/profile.d/guix.sh || true

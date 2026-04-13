set -e
apt-get update
apt-get -y install guix openssl
. /etc/profile.d/guix.sh || true

guix pull

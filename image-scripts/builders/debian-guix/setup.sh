set -e
apt-get update
apt-get -y install guix
. /etc/profile.d/guix.sh || true

guix pull

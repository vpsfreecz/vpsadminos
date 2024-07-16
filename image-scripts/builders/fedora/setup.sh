set -e
dnf -y update
dnf -y install curl debootstrap git minisign openssl patch wget zstd

if [ "$BUILD_VARIANT" != "cloudinit" ]; then
	osctl ct exec $CTID type cloud-init && fail "cloud-init is installed in variant '$BUILD_VARIANT'"
	exit 0
fi

function install_script {
	cat <<EOF
#!/bin/sh

dst=/var/lib/cloud/seed/nocloud

mkdir -p \$dst
cat <<EOT > \$dst/meta-data
instance-id: $CTID
local-hostname: my-ct
EOT

cat <<EOT > \$dst/network-config
network:
  version: 2
  ethernets: {}
EOT

cat <<EOT > \$dst/user-data
#cloud-config
users:
  - name: myuser
    sudo: ALL=(ALL) NOPASSWD:ALL
runcmd:
  - echo "hello" > /root/cloud-init.txt
EOT

EOF
}

osctl ct runscript -r $CTID <(install_script)

osctl ct start $CTID || fail "unable to start container"

for i in {1..30} ; do
	sleep 1

	osctl ct exec $CTID id myuser || continue
	[ "$(osctl ct cat $CTID /root/cloud-init.txt)" == "hello" ] || continue

	exit 0
done

fail "cloud-init setup failed"

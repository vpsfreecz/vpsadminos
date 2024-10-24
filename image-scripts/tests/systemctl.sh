osctl ct start $CTID || fail "unable to start container"
sleep 10

if ! osctl ct exec $CTID type systemctl ; then
	echo "systemctl not found, ignoring"
	exit 0
fi

osctl ct exec $CTID systemctl is-system-running --wait && exit 0

echo "system is not running, systemctl --failed:"
osctl ct exec $CTID systemctl --failed
exit 1
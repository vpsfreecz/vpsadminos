#! @shell@

console=tty1

fail() {
    if [ -n "$panicOnFail" ]; then exit 1; fi

    # If starting stage 1 failed, allow the user to repair the problem
    # in an interactive shell.
    cat <<EOF

Error: [1;31m ${1} [0m

An error occurred in stage 1 of the boot process, which must import the
ZFS pool and then start stage 2. Press one
of the following keys:

  i) to launch an interactive shell
  n) to create pool with "@newPoolCmd@"
  r) to reboot immediately
  *) to ignore the error and continue
EOF

    read reply

    if [ "$reply" = i ]; then
        echo "Starting interactive shell..."
        setsid @shell@ -c "@shell@ < /dev/$console >/dev/$console 2>/dev/$console" || fail "Can't spawn shell"
    elif [ "$reply" = r ]; then
        echo "Rebooting..."
        reboot -f
    elif [ "$reply" = n ]; then
        @newPoolCmd@
    else
        echo "Continuing..."
    fi
}

trap 'fail' 0

echo
echo "[1;32m<<< vpsAdminOS Stage 1 >>>[0m"
echo

export LD_LIBRARY_PATH=@extraUtils@/lib
export PATH=@extraUtils@/bin/
mkdir -p /proc /sys /dev /etc/udev /tmp /run/ /lib/ /mnt/ /var/log /bin
mount -t devtmpfs devtmpfs /dev/
mount -t proc proc /proc
mount -t sysfs sysfs /sys

ln -sv @shell@ /bin/sh
ln -s @modules@/lib/modules /lib/modules

for x in @modprobeList@; do
  modprobe $x
done

root=/dev/vda
for o in $(cat /proc/cmdline); do
  case $o in
    console=*)
      set -- $(IFS==; echo $o)
      params=$2
      set -- $(IFS=,; echo $params)
      console=$1
      ;;
    systemConfig=*)
      set -- $(IFS==; echo $o)
      sysconfig=$2
      ;;
    root=*)
      set -- $(IFS==; echo $o)
      root=$2
      ;;
    netroot=*)
      set -- $(IFS==; echo $o)
      mkdir -pv /var/run /var/db
      sleep 5
      dhcpcd eth0 -c ${dhcpHook}
      tftp -g -r "$3" "$2"
      root=/root.squashfs
      ;;
  esac
done


echo "running udev..."
mkdir -p /etc/udev
ln -sfn @udevRules@ /etc/udev/rules.d
udevd --daemon
udevadm trigger --action=add
udevadm settle

@postDeviceCommands@

udevadm control --exit

mount -t tmpfs root /mnt/ -o size=6G || fail "Can't mount root tmpfs"
chmod 755 /mnt/
mkdir -p /mnt/nix/store/

# make the store writeable
mkdir -p /mnt/nix/.ro-store /mnt/nix/.overlay-store /mnt/nix/store
mount $root /mnt/nix/.ro-store -t squashfs
mount tmpfs -t tmpfs /mnt/nix/.overlay-store -o size=1G
mkdir -pv /mnt/nix/.overlay-store/work /mnt/nix/.overlay-store/rw
modprobe overlay
mount -t overlay overlay -o lowerdir=/mnt/nix/.ro-store,upperdir=/mnt/nix/.overlay-store/rw,workdir=/mnt/nix/.overlay-store/work /mnt/nix/store

exec env -i $(type -P switch_root) /mnt/ $sysconfig/init
exec ${shell}

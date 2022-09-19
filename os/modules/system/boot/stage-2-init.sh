#!@shell@

systemConfig=@systemConfig@
export PATH=@path@/bin/

# Print a greeting.
echo
echo -e "\e[1;32m<<< vpsAdminOS Stage 2 >>>\e[0m"
echo

mkdir -p /proc /sys /dev /tmp /var/log /etc /root /run /nix/var/nix/gcroots
mount -t proc proc /proc
if [ @procHidePid@ ]; then
  mount -o remount,rw,hidepid=2 /proc
fi
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts -ogid=3 devpts /dev/pts
mount -t tmpfs -o mode=1777 tmpfs /tmp
mount -t tmpfs -o mode=755 tmpfs /run
mount -t tmpfs tmpfs /dev/shm

ln -sfn /run /var/run
ln -sf /proc/mounts /etc/mtab

touch /run/{u,w}tmp
mkdir /run/wrappers /run/lock

chmod a+rxw /dev/kmsg
chmod a+rxw /proc/kmsg

hostname @hostName@

$systemConfig/activate

# Record the boot configuration.
ln -sfn "$systemConfig" /run/booted-system

# Prevent the booted system form being garbage-collected If it weren't
# a gcroot, if we were running a different kernel, switched system,
# and garbage collected all, we could not load kernel modules anymore.
ln -sfn /run/booted-system /nix/var/nix/gcroots/booted-system

# Run any user-specified commands.
@shell@ @postBootCommands@

exec runit

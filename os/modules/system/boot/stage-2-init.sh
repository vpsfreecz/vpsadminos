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
chmod a+r /proc/slabinfo

# Move secrets in place before making /nix/store read-only, otherwise
# mv will fail to remove them from /nix/store/secrets.
if [ -d /nix/store/secrets ] ; then
  [ -d /var/secrets ] && rm -rf /var/secrets
  mv /nix/store/secrets /var/secrets
fi

# Make /nix/store a read-only bind mount to enforce immutability of
# the Nix store.  Note that we can't use "chown root:nixbld" here
# because users/groups might not exist yet.
# Silence chown/chmod to fail gracefully on a readonly filesystem
# like squashfs.
chown -f 0:30000 /nix/store
chmod -f 1775 /nix/store
if [ -n "@readOnlyNixStore@" ]; then
  if ! [[ "$(findmnt --noheadings --output OPTIONS /nix/store)" =~ ro(,|$) ]]; then
    mount --bind /nix/store /nix/store
    mount -o remount,ro,bind /nix/store
  fi
fi

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

#!@shell@

systemConfig=@systemConfig@
export PATH=@path@/bin/

# Print a greeting.
echo
echo -e "\e[1;32m<<< vpsAdminOS Stage 2 >>>\e[0m"
echo

mkdir -p /proc /sys /dev /tmp /var/empty /var/log /etc /root /run /nix/var/nix/gcroots
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
mkdir /run/lock

mkdir @parentWrapperDir@
mount -t tmpfs -o nodev,mode=755,size=@wrapperDirSize@ tmpfs @parentWrapperDir@

chmod a+rxw /dev/kmsg
chmod a+rxw /proc/kmsg
chmod a+r /proc/slabinfo

# Apply the configured mount options on /nix/store to enforce immutability
# and harden the store. Note that we can't use "chown root:nixbld" here
# because users/groups might not exist yet.
# Silence chown/chmod to fail gracefully on a readonly filesystem
# like squashfs.
chown -f 0:30000 /nix/store
chmod -f 1775 /nix/store

missing_opts=() # stores the missing mount options that still need to be applied to the nix store
current_opts="$(findmnt --direction backward --first-only --noheadings --output OPTIONS /nix/store)"
for mount_opt in @nixStoreMountOpts@ ; do
  # matches '$opt', 'foo,$opt', '$opt,foo', 'foo,$opt,bar'
  # crucially, it does not match 'foo$opt', otherwise e.g. 'errors=remount-ro'
  # would yield false positives for 'ro'
  if ! [[ "$current_opts" =~ (^|,)"$mount_opt"(,|$) ]]; then
    missing_opts+=("$mount_opt")
  fi
done

# only change the mount options if any need changing
if [[ ${#missing_opts[@]} != 0 ]]; then
  mount --bind /nix/store /nix/store
  mount -o remount,"$(IFS=, ; echo "${missing_opts[*]}")",bind /nix/store
fi

hostname @hostName@

$systemConfig/activate

# Record the boot configuration.
ln -sfn "$systemConfig" /run/booted-system

# Prevent the booted system form being garbage-collected If it weren't
# a gcroot, if we were running a different kernel, switched system,
# and garbage collected all, we could not load kernel modules anymore.
ln -sfn /run/booted-system /nix/var/nix/gcroots/booted-system

# Prevent the current system from being garbage-collected
ln -sfn /run/current-system /nix/var/nix/gcroots/current-system

# Run any user-specified commands.
@shell@ @postBootCommands@

exec runit

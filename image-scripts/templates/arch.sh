DISTNAME=arch
RELVER=
BASEURL=http://mirror.vpsfree.cz/archlinux/iso/latest


# Using the Bootstrap Image
rline=`curl $BASEURL/md5sums.txt | grep bootstrap | grep x86_64`
bfile=${rline##* }
RELVER=`echo $bfile | awk -F- '{print $3}'`

wget -P $DOWNLOAD $BASEURL/$bfile
md5s=`md5sum $DOWNLOAD/$bfile`
if [ ${rline%% *} != ${md5s%% *} ]; then
	echo "Bootstrap checksum wrong! Quitting."
	exit 1
fi
cd $INSTALL
gzip -dc $DOWNLOAD/$bfile | tar x --preserve-permissions --preserve-order --numeric-owner --one-top-level=$INSTALL

INSTALL1=$INSTALL/root.x86_64

sed -ri 's/^#(.*vpsfree\.cz.*)$/\1/' $INSTALL1/etc/pacman.d/mirrorlist
CHROOT="$INSTALL1/bin/arch-chroot $INSTALL1"
# Initializing pacman keyring
$CHROOT pacman-key --init
$CHROOT pacman-key --populate archlinux

# Install the base system
$CHROOT pacstrap -dG /mnt base openssh

INSTALL2=$INSTALL1/mnt

# Configure the system
#$CHROOT genfstab -p /mnt >> /mnt/etc/fstab
cat >> $INSTALL2/etc/fstab <<EOF
tmpfs           /tmp    tmpfs   nodev,nosuid    0       0
devpts  /dev/pts        devpts  gid=5,mode=620  0       0
LABEL=/ /               ext4    defaults
EOF

CHROOT2="$CHROOT arch-chroot /mnt"

# Downgrade systemd
mkdir -p $INSTALL2/root/pkgs
cp $BASEDIR/packages/arch/* $INSTALL2/root/pkgs
$CHROOT2 pacman -Rnsdd --noconfirm libsystemd
for lpkg in `cd $INSTALL2/root/pkgs && ls -1 *.pkg.tar.xz`; do
	$CHROOT2 pacman -U --noconfirm /root/pkgs/$lpkg
done
rm -rf $INSTALL2/root/pkgs


$CHROOT2 pacman -Rns --noconfirm linux
yes | $CHROOT2 pacman -Scc
$CHROOT2 ln -s /usr/share/zoneinfo/Europe/Prague /etc/localtime
$CHROOT2 systemctl enable sshd
sed -ri 's/^#( *IgnorePkg *=.*)$/\1 systemd systemd-sysvcompat python2-systemd/' $INSTALL2/etc/pacman.conf


cd $INSTALL
rm -f $INSTALL2/etc/machine-id $INSTALL2/root/.bash_history
mv $INSTALL2/* $INSTALL
rm -r $INSTALL1

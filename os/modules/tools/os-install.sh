#! @shell@

set -e
shopt -s nullglob

export PATH=@path@:$PATH

# Ensure a consistent umask.
umask 0022

# Parse the command line for the -I flag
extraBuildFlags=()

mountPoint=/install
channelPath=
system=

while [ "$#" -gt 0 ]; do
    i="$1"; shift 1
    case "$i" in
        --max-jobs|-j|--cores|-I|--substituters)
            j="$1"; shift 1
            extraBuildFlags+=("$i" "$j")
            ;;
        --option)
            j="$1"; shift 1
            k="$1"; shift 1
            extraBuildFlags+=("$i" "$j" "$k")
            ;;
        --root)
            mountPoint="$1"; shift 1
            ;;
        --system|--closure)
            system="$1"; shift 1
            ;;
        --channel)
            channelPath="$1"; shift 1
            ;;
        --no-channel-copy)
            noChannelCopy=1
            ;;
        --no-root-passwd)
            noRootPasswd=1
            ;;
        --no-bootloader)
            noBootLoader=1
            ;;
        --show-trace)
            extraBuildFlags+=("$i")
            ;;
        --help)
            exec man nixos-install
            exit 1
            ;;
        --debug)
            set -x
            ;;
        *)
            echo "$0: unknown option \`$i'"
            exit 1
            ;;
    esac
done

if ! test -e "$mountPoint"; then
    echo "mount point $mountPoint doesn't exist"
    exit 1
fi

# Get the path of the NixOS configuration file.
if [[ -z $VPSADMINOS_CONFIG ]]; then
    VPSADMINOS_CONFIG=$mountPoint/etc/vpsadminos/configuration.nix
fi

if [[ ${VPSADMINOS_CONFIG:0:1} != / ]]; then
    echo "$0: \$VPSADMINOS_CONFIG is not an absolute path"
    exit 1
fi

if [[ ! -e $VPSADMINOS_CONFIG && -z $system ]]; then
    echo "configuration file $VPSADMINOS_CONFIG doesn't exist"
    exit 1
fi

# A place to drop temporary stuff.
trap "rm -rf $tmpdir" EXIT
tmpdir="$(mktemp -d)"

sub="auto?trusted=1"

# Build the system configuration in the target filesystem.
if [[ -z $system ]]; then
    echo "building the configuration in $VPSADMINOS_CONFIG..."
    outLink="$tmpdir/system"
    nix-build --out-link "$outLink" --store "$mountPoint" "${extraBuildFlags[@]}" \
        --extra-substituters "$sub" \
        '<vpsadminos/os>' -A config.system.build.toplevel --arg configuration "$VPSADMINOS_CONFIG"
    system=$(readlink -f $outLink)
fi

# Set the system profile to point to the configuration. TODO: combine
# this with the previous step once we have a nix-env replacement with
# a progress bar.
nix-env --store "$mountPoint" "${extraBuildFlags[@]}" \
        --extra-substituters "$sub" \
        -p $mountPoint/nix/var/nix/profiles/system --set "$system"

# Copy the NixOS/Nixpkgs sources to the target as the initial contents
# of the NixOS channel.
if [[ -z $noChannelCopy ]]; then
    if [[ -z $channelPath ]]; then
        channelPath="$(nix-env -p /nix/var/nix/profiles/per-user/root/channels -q nixos vpsadminos --no-name --out-path 2>/dev/null || echo -n "")"
    fi
    if [[ -n $channelPath ]]; then
        echo "copying channel..."
        mkdir -p $mountPoint/nix/var/nix/profiles/per-user/root
        nix-env --store "$mountPoint" "${extraBuildFlags[@]}" --extra-substituters "$sub" \
                -p $mountPoint/nix/var/nix/profiles/per-user/root/channels --install $channelPath --quiet
        install -m 0700 -d $mountPoint/root/.nix-defexpr
        ln -sfn /nix/var/nix/profiles/per-user/root/channels $mountPoint/root/.nix-defexpr/channels
    fi
fi

# Mark the target look like as a NixOS installation, otherwise switch-to-configuration will chicken out.
mkdir -m 0755 -p "$mountPoint/etc"
mkdir -m 0755 -p "$mountPoint/run"
touch "$mountPoint/etc/VPSADMINOS"

# Switch to the new system configuration.  This will install Grub with
# a menu default pointing at the kernel/initrd/etc of the new
# configuration.
if [[ -z $noBootLoader ]]; then
    echo "installing the boot loader..."
    # Grub needs an mtab.
    ln -sfn /proc/mounts $mountPoint/etc/mtab
    OS_INSTALL_BOOTLOADER=1 os-enter --root "$mountPoint" -- /run/current-system/bin/switch-to-configuration boot
fi

# Ask the user to set a root password, but only if the passwd command
# exists (i.e. when mutable user accounts are enabled).
if [[ -z $noRootPasswd ]] && [ -t 0 ]; then
    os-enter --root "$mountPoint" -c '[[ -e /nix/var/nix/profiles/system/sw/bin/passwd ]] && echo "setting root password..." && /nix/var/nix/profiles/system/sw/bin/passwd'
fi

echo "installation finished!"

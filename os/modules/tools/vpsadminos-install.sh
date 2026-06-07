#! @shell@

set -euo pipefail
shopt -s nullglob

export PATH=@nix@/bin:@path@:$PATH

# Ensure a consistent umask.
umask 0022

show_help() {
    cat <<'EOF'
Usage: vpsadminos-install [--root PATH] [--flake FLAKE] [--system PATH] [options]

Install vpsAdminOS into a mounted target root.

By default, the system is built from /mnt/etc/vpsadminos using the current
hostname as vpsadminosConfigurations.<hostname>. Pass --flake PATH#HOST to
select a different flake or configuration name.
EOF
}

nix=(@nix@/bin/nix --extra-experimental-features "nix-command flakes")
extraBuildFlags=()

mountPoint=/mnt
flakeRef="${VPSADMINOS_FLAKE:-}"
configurationName="${VPSADMINOS_HOSTNAME:-}"
system=
noBootLoader=
noRootPasswd=

need_arg() {
    if [[ $# -lt 2 || -z ${2:-} ]]; then
        echo "$0: '$1' requires an argument" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    i="$1"; shift 1
    case "$i" in
        --help)
            show_help
            exit 0
            ;;
        --debug)
            set -x
            ;;
        --root)
            need_arg "$i" "${1-}"
            mountPoint="$1"; shift 1
            ;;
        --flake)
            need_arg "$i" "${1-}"
            flakeRef="$1"; shift 1
            ;;
        --hostname|--configuration)
            need_arg "$i" "${1-}"
            configurationName="$1"; shift 1
            ;;
        --system|--closure|--store-path)
            need_arg "$i" "${1-}"
            system="$1"; shift 1
            ;;
        --no-root-password|--no-root-passwd)
            noRootPasswd=1
            ;;
        --no-bootloader)
            noBootLoader=1
            ;;
        --channel|--no-channel-copy)
            if [[ "$i" = "--channel" ]]; then
                need_arg "$i" "${1-}"
                shift 1
            fi
            echo "$0: $i is ignored; vpsAdminOS installation uses flakes" >&2
            ;;
        --max-jobs|-j|--cores|-I|--substituters|--extra-substituters|--log-format|--inputs-from|--update-input)
            need_arg "$i" "${1-}"
            extraBuildFlags+=("$i" "$1"); shift 1
            ;;
        --option|--override-input)
            need_arg "$i" "${1-}"
            j="$1"; shift 1
            need_arg "$i" "${1-}"
            k="$1"; shift 1
            extraBuildFlags+=("$i" "$j" "$k")
            ;;
        --show-trace|--impure|--keep-going|--refresh|--offline|--no-write-lock-file|--no-update-lock-file|--recreate-lock-file|--print-build-logs|-L)
            extraBuildFlags+=("$i")
            ;;
        *)
            echo "$0: unknown option '$i'" >&2
            exit 1
            ;;
    esac
done

if [[ ! -e $mountPoint ]]; then
    echo "mount point $mountPoint doesn't exist" >&2
    exit 1
fi

checkPath="$(realpath "$mountPoint")"
while [[ "$checkPath" != "/" ]]; do
    mode="$(stat -c '%a' "$checkPath")"
    if [[ "${mode: -1}" -lt "5" ]]; then
        echo "path $checkPath should have permissions 755, but had permissions $mode. Consider running 'chmod o+rx $checkPath'." >&2
        exit 1
    fi
    checkPath="$(dirname "$checkPath")"
done

if [[ -z $configurationName ]]; then
    configurationName="$(hostname)"
fi

if [[ -z $flakeRef ]]; then
    flakeRef="$mountPoint/etc/vpsadminos"
fi

flake_installable() {
    local ref="$1"
    local name="$2"
    local base attr

    if [[ "$ref" == *#* ]]; then
        base="${ref%%#*}"
        attr="${ref#*#}"
        [[ -n $attr ]] || attr="$name"
    else
        base="$ref"
        attr="$name"
    fi

    if [[ $attr == vpsadminosConfigurations.* || $attr == packages.* || $attr == legacyPackages.* || $attr == *config.system.build* ]]; then
        printf '%s#%s\n' "$base" "$attr"
    else
        printf '%s#vpsadminosConfigurations.%s.config.system.build.toplevel\n' "$base" "$attr"
    fi
}

sub="auto?trusted=1"
profile="$mountPoint/nix/var/nix/profiles/system"
mkdir -m 0755 -p "$(dirname "$profile")"

if [[ -z $system ]]; then
    installable="$(flake_installable "$flakeRef" "$configurationName")"
    echo "building the system configuration from $installable..."
else
    installable="$system"
    echo "installing prebuilt system $installable..."
fi

system="$(
    "${nix[@]}" build \
      --store "$mountPoint" \
      --extra-substituters "$sub" \
      --profile "$profile" \
      --print-out-paths \
      "${extraBuildFlags[@]}" \
      "$installable"
)"

# Mark the target as a vpsAdminOS installation, otherwise switch-to-configuration
# will refuse to operate.
mkdir -m 0755 -p "$mountPoint/etc" "$mountPoint/run"
touch "$mountPoint/etc/VPSADMINOS"
ln -sfn /nix/var/nix/profiles/system "$mountPoint/run/current-system"

# Switch to the new system configuration.  This will install the boot loader with
# a menu default pointing at the kernel/initrd/etc of the new configuration.
if [[ -z $noBootLoader ]]; then
    echo "installing the boot loader..."
    ln -sfn /proc/mounts "$mountPoint/etc/mtab"
    export mountPoint
    NIXOS_INSTALL_BOOTLOADER=1 VPSADMINOS_INSTALL_BOOTLOADER=1 vpsadminos-enter --root "$mountPoint" -c "$(cat <<'EOF'
      set -e
      hash -r
      # Preserve absolute mount paths used by bootloader evaluation after
      # vpsadminos-enter changes root to the target filesystem.
      mount --rbind --mkdir / "$mountPoint"
      mount --make-rslave "$mountPoint"
      mkdir -p /run
      ln -sfn /nix/var/nix/profiles/system /run/current-system
      /nix/var/nix/profiles/system/bin/switch-to-configuration boot
      umount -R "$mountPoint" && (rmdir "$mountPoint" 2>/dev/null || true)
EOF
)"
fi

# Ask the user to set a root password, but only if the passwd command exists
# and stdin is interactive.
if [[ -z $noRootPasswd && -t 0 ]]; then
    vpsadminos-enter --root "$mountPoint" -c '[[ -e /nix/var/nix/profiles/system/sw/bin/passwd ]] && echo "setting root password..." && /nix/var/nix/profiles/system/sw/bin/passwd'
fi

echo "installation finished!"

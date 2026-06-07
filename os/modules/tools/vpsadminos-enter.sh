#! @shell@

set -e

export PATH=@path@:$PATH

show_help() {
    cat <<'EOF'
Usage: vpsadminos-enter [--root PATH] [--system PATH] [--silent] [-- COMMAND...]
       vpsadminos-enter [--root PATH] [--system PATH] --command COMMAND

Enter a mounted vpsAdminOS installation.
EOF
}

# Re-exec ourselves in a private mount namespace so that our bind
# mounts get cleaned up automatically.
if [ -z "$VPSADMINOS_ENTER_REEXEC" ]; then
    export VPSADMINOS_ENTER_REEXEC=1
    if [ "$(id -u)" != 0 ]; then
        extraFlags="-r"
    fi
    exec unshare --fork --mount --uts --mount-proc --pid $extraFlags -- "$0" "$@"
else
    mount --make-rprivate /
fi

mountPoint=/mnt
system=/nix/var/nix/profiles/system
commandMode=login
commandArg=
command=()
silent=0

while [ "$#" -gt 0 ]; do
    i="$1"; shift 1
    case "$i" in
        --root)
            mountPoint="$1"; shift 1
            ;;
        --system)
            system="$1"; shift 1
            ;;
        --help)
            show_help
            exit 0
            ;;
        --command|-c)
            commandMode=command
            commandArg="$1"
            shift 1
            ;;
        --silent)
            silent=1
            ;;
        --)
            commandMode=args
            command=("$@")
            break
            ;;
        *)
            echo "$0: unknown option \`$i'"
            exit 1
            ;;
    esac
done

case "$commandMode" in
    login)
        command=("$system/sw/bin/bash" "--login")
        ;;
    command)
        command=("$system/sw/bin/bash" "-c" "$commandArg")
        ;;
    args)
        ;;
esac

test -f "$mountPoint/etc/VPSADMINOS" || {
    echo "$0: '$mountPoint' is not a vpsAdminOS installation" >&2
    exit 126
}

mkdir -p "$mountPoint/dev" "$mountPoint/sys" "$mountPoint/proc"
chmod 0755 "$mountPoint/dev" "$mountPoint/sys" "$mountPoint/proc"
mount --rbind /dev "$mountPoint/dev"
mount --rbind /sys "$mountPoint/sys"
mount --rbind /proc "$mountPoint/proc"

chroot_add_resolv_conf() {
    local chrootDir="$1" resolvConf="$1/etc/resolv.conf"

    [[ -e /etc/resolv.conf ]] || return 0

    if [[ -L "$resolvConf" ]]; then
      resolvConf="$(readlink "$resolvConf")"
      if [[ "$resolvConf" = /* ]]; then
        resolvConf="$chrootDir$resolvConf"
      else
        resolvConf="$chrootDir/etc/$resolvConf"
      fi
    fi

    if [[ ! -f "$resolvConf" ]]; then
      install -Dm644 /dev/null "$resolvConf" || return 1
    fi

    mount --bind /etc/resolv.conf "$resolvConf"
}

chroot_add_resolv_conf "$mountPoint" || echo "$0: failed to set up resolv.conf" >&2

(
    if [ "$silent" -eq 1 ]; then
        exec 2>/dev/null
    fi

    # Run the activation script. Set $LOCALE_ARCHIVE to suppress Perl locale warnings.
    if [ -x "$mountPoint$system/activate" ]; then
        LOCALE_ARCHIVE="$system/sw/lib/locale/locale-archive" IN_VPSADMINOS_ENTER=1 chroot "$mountPoint" "$system/activate" 1>&2 || true
    fi
)

unset TMPDIR

exec chroot "$mountPoint" "${command[@]}"

#! @shell@

if [ -x "@shell@" ]; then export SHELL="@shell@"; fi

set -euo pipefail

export PATH=@nix@/bin:$PATH

show_syntax() {
    cat <<'EOF'
Usage: vpsadminos-rebuild switch|boot|test|build|dry-build|dry-activate [options]
       vpsadminos-rebuild build-vm|build-vm-with-bootloader [options]

Build and activate a vpsAdminOS system configuration.

The default flake is /etc/vpsadminos#$(hostname), resolved as
vpsadminosConfigurations.<hostname>.config.system.build.toplevel.
EOF
    exit "${1:-1}"
}

nix=(@nix@/bin/nix --extra-experimental-features "nix-command flakes")

extraBuildFlags=()
action=
flakeRef="${VPSADMINOS_FLAKE:-/etc/vpsadminos}"
configurationName="${VPSADMINOS_HOSTNAME:-}"
profile=/nix/var/nix/profiles/system
rollback=
upgrade=
buildHost=
targetHost=

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
        show_syntax 0
        ;;
      switch|boot|test|build|dry-build|dry-run|dry-activate|build-vm|build-vm-with-bootloader)
        if [[ "$i" = dry-run ]]; then i=dry-build; fi
        action="$i"
        ;;
      --flake)
        need_arg "$i" "${1-}"
        flakeRef="$1"; shift 1
        ;;
      --hostname|--configuration)
        need_arg "$i" "${1-}"
        configurationName="$1"; shift 1
        ;;
      --install-grub)
        echo "$0: --install-grub is deprecated, use --install-bootloader instead" >&2
        export NIXOS_INSTALL_BOOTLOADER=1
        export VPSADMINOS_INSTALL_BOOTLOADER=1
        ;;
      --install-bootloader)
        export NIXOS_INSTALL_BOOTLOADER=1
        export VPSADMINOS_INSTALL_BOOTLOADER=1
        ;;
      --rollback)
        rollback=1
        ;;
      --upgrade)
        upgrade=1
        ;;
      --fast|--no-build-nix)
        # Kept as a compatibility no-op. Flake builds use the Nix package from
        # this tool's closure directly.
        ;;
      --profile-name|-p)
        need_arg "$i" "${1-}"
        if [[ "$1" != system ]]; then
            profile="/nix/var/nix/profiles/system-profiles/$1"
            mkdir -p -m 0755 "$(dirname "$profile")"
        fi
        shift 1
        ;;
      --build-host|h)
        need_arg "$i" "${1-}"
        buildHost="$1"; shift 1
        ;;
      --target-host|t)
        need_arg "$i" "${1-}"
        targetHost="$1"; shift 1
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
      --show-trace|--impure|--keep-failed|-K|--keep-going|-k|--verbose|-v|-vv|-vvv|-vvvv|-vvvvv|--fallback|--repair|--refresh|--offline|--no-build-output|-Q|--no-write-lock-file|--no-update-lock-file|--recreate-lock-file|--print-build-logs|-L|-j*)
        extraBuildFlags+=("$i")
        ;;
      *)
        echo "$0: unknown option '$i'" >&2
        exit 1
        ;;
    esac
done

if [[ -z $action ]]; then show_syntax; fi

if [[ -n $buildHost || -n $targetHost ]]; then
    echo "$0: --build-host and --target-host are not supported by the flake-only rebuild path yet" >&2
    exit 1
fi

if [[ -z $configurationName ]]; then
    configurationName="$(hostname)"
fi

flake_parts() {
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

    printf '%s\n%s\n' "$base" "$attr"
}

flake_installable() {
    local ref="$1"
    local name="$2"
    local output="$3"
    local base attr

    mapfile -t parts < <(flake_parts "$ref" "$name")
    base="${parts[0]}"
    attr="${parts[1]}"

    if [[ $attr == vpsadminosConfigurations.* || $attr == packages.* || $attr == legacyPackages.* || $attr == *config.system.build* ]]; then
        printf '%s#%s\n' "$base" "$attr"
    else
        printf '%s#vpsadminosConfigurations.%s.config.system.build.%s\n' "$base" "$attr" "$output"
    fi
}

tmpDir="$(mktemp -t -d vpsadminos-rebuild.XXXXXX)"
cleanup() {
    rm -rf "$tmpDir"
}
trap cleanup EXIT

if [[ -n $upgrade ]]; then
    mapfile -t parts < <(flake_parts "$flakeRef" "$configurationName")
    flakeBase="${parts[0]}"
    if [[ -z $flakeBase ]]; then
        flakeBase=.
    fi
    if [[ "$flakeBase" == *:* && "$flakeBase" != path:* ]]; then
        echo "$0: --upgrade requires a local flake path" >&2
        exit 1
    fi
    "${nix[@]}" flake update "$flakeBase"
fi

case "$action" in
  build-vm)
    output=vm
    ;;
  build-vm-with-bootloader)
    output=vmWithBootLoader
    ;;
  *)
    output=toplevel
    ;;
esac

installable="$(flake_installable "$flakeRef" "$configurationName" "$output")"

if [[ -n $rollback ]]; then
    case "$action" in
      switch|boot)
        "${nix[@]}" profile rollback --profile "$profile"
        pathToConfig="$(readlink -f "$profile")"
        ;;
      test|build)
        pathToConfig="$(readlink -f "$profile")"
        if [[ "$action" = build ]]; then
            ln -sfn "$pathToConfig" ./result
        fi
        ;;
      *)
        show_syntax
        ;;
    esac
else
    echo "building the system configuration from $installable..." >&2
    case "$action" in
      switch|boot)
        mkdir -p -m 0755 "$(dirname "$profile")"
        pathToConfig="$(
            "${nix[@]}" build \
              --profile "$profile" \
              --print-out-paths \
              "${extraBuildFlags[@]}" \
              "$installable"
        )"
        ;;
      test|dry-activate)
        pathToConfig="$(
            "${nix[@]}" build \
              --out-link "$tmpDir/system" \
              --print-out-paths \
              "${extraBuildFlags[@]}" \
              "$installable"
        )"
        ;;
      build|build-vm|build-vm-with-bootloader)
        pathToConfig="$(
            "${nix[@]}" build \
              --out-link result \
              --print-out-paths \
              "${extraBuildFlags[@]}" \
              "$installable"
        )"
        ;;
      dry-build)
        "${nix[@]}" build --dry-run "${extraBuildFlags[@]}" "$installable"
        exit 0
        ;;
      *)
        show_syntax
        ;;
    esac
fi

if [[ "$action" = switch || "$action" = boot || "$action" = test || "$action" = dry-activate ]]; then
    if ! "$pathToConfig/bin/switch-to-configuration" "$action"; then
        echo "warning: error(s) occurred while switching to the new configuration" >&2
        exit 1
    fi
fi

if [[ "$action" = build-vm ]]; then
    cat >&2 <<EOF

Done. The virtual machine can be started by running $(echo "$pathToConfig"/bin/run-*-vm)
EOF
fi

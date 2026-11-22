function nixos-template-channel {
	case "$1" in
		nixos-25.11) printf '%s\n' 25_11 ;;
		nixos-26.05) printf '%s\n' 26_05 ;;
		nixos-26.11) printf '%s\n' stable ;;
		nixos-unstable) printf '%s\n' unstable ;;
		*) return 1 ;;
	esac
}

function build-nixos {
	local vpsadminos=
	local vpsadminos_rev=
	local nix_config=
	local template_channel=

	template_channel="$(nixos-template-channel "$CHANNEL")" \
		|| fail "unsupported NixOS image channel: $CHANNEL"

	[ -n "${OSCTL_IMAGE_VPSADMINOS_DIR-}" ] \
		|| fail "path to vpsadminos sources not provided"
	[ -d "$OSCTL_IMAGE_VPSADMINOS_DIR/os" ] \
		|| fail "invalid vpsadminos checkout: $OSCTL_IMAGE_VPSADMINOS_DIR"

	vpsadminos_rev="${OSCTL_IMAGE_VPSADMINOS_REV-}"
	if [ -z "$vpsadminos_rev" ]; then
		vpsadminos_rev="$(git -C "$OSCTL_IMAGE_VPSADMINOS_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
	fi

	cp -a "$OSCTL_IMAGE_VPSADMINOS_DIR" "$PWD/vpsadminos" \
		|| fail "unable to copy vpsadminos from $OSCTL_IMAGE_VPSADMINOS_DIR"

	vpsadminos="$PWD/vpsadminos"
	chmod -R u+rwX,go+rX "$vpsadminos"
	if [ -n "$vpsadminos_rev" ]; then
		printf '%s\n' "$vpsadminos_rev" > "$vpsadminos/.vpsadminos-git-rev"
	fi
	rm -rf "$vpsadminos/.git" "$vpsadminos/result"

	cd "$vpsadminos/os"

	case "$VARIANT" in
		impermanence)
			build_command="make template-impermanence"
			result_dir=template-impermanence
			;;
		*)
			build_command="make template"
			result_dir=template
	esac

	if [ -n "${NIX_CONFIG-}" ] ; then
		nix_config="$NIX_CONFIG
experimental-features = nix-command flakes"
	else
		nix_config="experimental-features = nix-command flakes"
	fi

	NIX_CONFIG="$nix_config" \
		$build_command TEMPLATE_CHANNEL="$template_channel" || fail "failed to build the template"

	tar -xzf result/$result_dir/tarball/*.tar.gz -C "$INSTALL"
	mv "$INSTALL/nix-path-registration" "$INSTALL/nix/nix-path-registration"
}

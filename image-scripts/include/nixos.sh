function build-nixos {
	local vpsadminos=
	local vpsadminos_rev=
	local nix_config=

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

	if [ "$CHANNEL" == "nixos-unstable" ] ; then
		TEMPLATE_CHANNEL=unstable
	else
		TEMPLATE_CHANNEL=stable
	fi

	if [ -n "${NIX_CONFIG-}" ] ; then
		nix_config="$NIX_CONFIG
experimental-features = nix-command flakes"
	else
		nix_config="experimental-features = nix-command flakes"
	fi

	NIX_CONFIG="$nix_config" \
		$build_command TEMPLATE_CHANNEL=$TEMPLATE_CHANNEL || fail "failed to build the template"

	tar -xzf result/$result_dir/tarball/*.tar.gz -C "$INSTALL"
	mv "$INSTALL/nix-path-registration" "$INSTALL/nix/nix-path-registration"
}

function build-nixos {
	local vpsadminos=
	local nix_config=

	git clone --depth 1 https://github.com/vpsfreecz/vpsadminos.git \
		|| fail "unable to fetch vpsadminos"
	vpsadminos="$PWD/vpsadminos"
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

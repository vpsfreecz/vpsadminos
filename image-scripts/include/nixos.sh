OS_BRANCH=staging

function build-nixos {
	local vpsadminos=
	local nixpkgs=

	curl -L https://github.com/vpsfreecz/vpsadminos/archive/$OS_BRANCH.tar.gz \
		| tar -xz \
		|| fail "unable to fetch vpsadminos"
	vpsadminos="$PWD/vpsadminos-$OS_BRANCH"

	curl -L https://nixos.org/channels/$CHANNEL/nixexprs.tar.xz \
		| tar -xJ \
		|| fail "unable to fetch nixpkgs"
	nixpkgs=$(echo $PWD/nixos-*)

	export NIX_PATH="nixpkgs=$nixpkgs:vpsadminos=$vpsadminos"
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

	$build_command || fail "failed to build the template"

	tar -xzf result/$result_dir/tarball/*.tar.gz -C "$INSTALL"
	mv "$INSTALL/nix-path-registration" "$INSTALL/nix/nix-path-registration"
}

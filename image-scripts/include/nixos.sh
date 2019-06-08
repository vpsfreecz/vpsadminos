OS_BRANCH=master

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
	make template || fail "failed to build the template"

	tar -xzf result/template/tarball/*.tar.gz -C "$INSTALL"
}

[ -n "${OSCTL_IMAGE_VPSADMINOS_DIR-}" ] \
  || { echo "path to vpsadminos sources not provided" >&2; exit 1; }
[ -d "$OSCTL_IMAGE_VPSADMINOS_DIR/os" ] \
  || { echo "invalid vpsadminos checkout: $OSCTL_IMAGE_VPSADMINOS_DIR" >&2; exit 1; }

vpsadminos=$(mktemp -d /tmp/vpsadminos.XXXXXXXX)
trap 'rm -rf "$vpsadminos"' EXIT
vpsadminos_rev="${OSCTL_IMAGE_VPSADMINOS_REV-}"
if [ -z "$vpsadminos_rev" ]; then
  vpsadminos_rev=$(
    git -C "$OSCTL_IMAGE_VPSADMINOS_DIR" rev-parse --verify HEAD 2>/dev/null \
      || true
  )
fi

cp -a "$OSCTL_IMAGE_VPSADMINOS_DIR/." "$vpsadminos" \
  || { echo "unable to copy vpsadminos from $OSCTL_IMAGE_VPSADMINOS_DIR" >&2; exit 1; }
chmod -R u+rwX,go+rX "$vpsadminos"
if [ -n "$vpsadminos_rev" ]; then
  printf '%s\n' "$vpsadminos_rev" > "$vpsadminos/.vpsadminos-git-rev"
fi
rm -rf "$vpsadminos/.git" "$vpsadminos/result"

vpsadminos_input_url="path:${vpsadminos}"

cat <<EOF > /etc/nixos/flake.nix
{
  inputs.vpsadminos.url = "${vpsadminos_input_url}";
  inputs.nixpkgs.follows = "vpsadminos/nixpkgsUnstable";

  outputs = { nixpkgs, vpsadminos, ... }: {
    nixosConfigurations.vps = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        vpsadminos.nixosModules.containerUnstable
      ];
    };
  };
}
EOF

cat <<EOF > /etc/nixos/configuration.nix
{ lib, pkgs, ... }:
{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    git
    gnumake
  ];

  time.timeZone = "Europe/Amsterdam";
  system.stateVersion = lib.trivial.release;
}
EOF

rm -f /etc/nixos/flake.lock

if [ -n "${NIX_CONFIG-}" ] ; then
  export NIX_CONFIG="$NIX_CONFIG
experimental-features = nix-command flakes"
else
  export NIX_CONFIG="experimental-features = nix-command flakes"
fi

# Set PATH and other login shell defaults
. /etc/profile

# Configure the system from the template flake
nixos-rebuild switch --flake /etc/nixos#vps

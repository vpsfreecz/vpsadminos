DISTNAME=nixos
CHANNEL=unstable
#CHANNEL=16.09

. $INCLUDE/nixos.sh

type nix-build &> /dev/null || bootstrap-nix
type nix-build &> /dev/null || echo "nix build not found"
build-nixos "${CHANNEL}"

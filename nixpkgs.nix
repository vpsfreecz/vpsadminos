# Used by ci.nix, update with
# $ nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/${REVISION}.tar.gz
#
import (
  fetchTarball {
    url = https://github.com/NixOS/nixpkgs/archive/26d8a8c0eb2a88d55694249b099cdd2c89b2b06d.tar.gz;
    sha256 = "0ag0hvwv98imxbbbg73qdf2dr4llp6vxykg24jc2j6l2zcsz3kc4";
  }
) {
  config = {};
  overlays = [];
}

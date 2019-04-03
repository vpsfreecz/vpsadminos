# Used by ci.nix, update with
# $ nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/${REVISION}.tar.gz
#
import (
  fetchTarball {
    url = https://github.com/vpsfreecz/nixpkgs/archive/5dd15a4181fb260d1c006c4d00e4cc978cd89989.tar.gz;
    sha256 = "0yg9059n08469mndvpq1f5x3lcnj9zrynkckwh9pii1ihimj6xyl";
  }
) {
  config = {};
  overlays = [];
}

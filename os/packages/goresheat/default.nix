{ pkgs, lib, buildGoModule }:

buildGoModule {
  pname = "goresheat";
  version = "1.1";

  src = pkgs.fetchFromGitHub {
    owner = "snajpa";
    repo = "goresheat";
    rev = "7cabfb77b5aa38a7b3f88d0e39635de2a12facca";
    sha256 = "sha256-FZ7Rdd+l0iwd+qunMazuf4WHGnPfZLL5t24x2Z2ejms=";
  };

  vendorHash = "sha256-iVGS9bvZ01AKuaFt1XLOKp6gW1NnPYTk0LoZzjsNmTg=";

  meta = with lib; {
    description = "Go Resource monitor";
    homepage    = https://github.com/snajpa/goresheat;
    license     = licenses.unlicense;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

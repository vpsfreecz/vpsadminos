{ pkgs, lib, buildGoModule }:

buildGoModule {
  pname = "goresheat";
  version = "1.1";

  src = pkgs.fetchFromGitHub {
    owner = "snajpa";
    repo = "goresheat";
    rev = "a2938f28e349f271099f17e21ed1121a2266ca31";
    sha256 = "sha256-rUWUmZkV09O34qUi/2GNQPYH9u9AY6WtT11RyZ7+s1Q=";
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

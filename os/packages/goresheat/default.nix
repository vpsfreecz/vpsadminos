{ pkgs, lib, buildGoModule }:

buildGoModule {
  pname = "goresheat";
  version = "1.2";

  src = pkgs.fetchFromGitHub {
    owner = "snajpa";
    repo = "goresheat";
    rev = "cfbfe7fd292d2e640dd3775c216b7e48ca4f497a";
    sha256 = "sha256-Yl8vnMU4BFM6WYv7PIFS9vyzR7D9wbMN/MS0g1eT4hA=";
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

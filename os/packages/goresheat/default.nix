{ pkgs, lib, buildGoModule }:

buildGoModule {
  pname = "goresheat";
  version = "1.1";

  src = pkgs.fetchFromGitHub {
    owner = "snajpa";
    repo = "goresheat";
    rev = "79e1522bb1fbe1cc65525ff6e6884f42ec8e9001";
    sha256 = "sha256-ybO3xQtwOui5UXtFQcd7k+c15i4MHrZJTYMsKTmTKU8=";
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

{ pkgs, lib, buildGoModule }:

buildGoModule {
  pname = "goresheat";
  version = "1.1";

  src = pkgs.fetchFromGitHub {
    owner = "snajpa";
    repo = "goresheat";
    rev = "a62afb7d1b4a123e8949cb35bc896d96ffb906ef";
    sha256 = "sha256-DWpXf/sP7rC3fjQFfL0ARm0FMigTkYqluct5sGIzcsY=";
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

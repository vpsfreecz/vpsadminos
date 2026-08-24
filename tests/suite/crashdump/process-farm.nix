{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "crashdump-process-farm";
  version = "1";
  src = ./process-farm.c;
  dontUnpack = true;

  buildPhase = ''
    $CC -std=gnu11 -O2 -Wall -Wextra -Werror \
      -o crash-process-farm $src
  '';

  installPhase = ''
    install -Dm755 crash-process-farm $out/bin/crash-process-farm
  '';
}

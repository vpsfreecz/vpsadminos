{ stdenv }:

stdenv.mkDerivation {
  pname = "write-boot-utmp";
  version = "1.0";

  src = ./write-boot-utmp.c;
  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    $CC $src -o $out/bin/write-boot-utmp

    runHook postInstall
  '';
}

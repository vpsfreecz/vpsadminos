{
  pkgs,
  getopt,
  fetchFromGitHub,
  ...
}:
pkgs.stdenv.mkDerivation rec {
  name = "makedumpfile";
  src = fetchFromGitHub {
    owner = "makedumpfile";
    repo = "makedumpfile";
    rev = "c81e096287623a9695c47f54d47c7114d05840e2";
    sha256 = "sha256-ZEejJSPiEHYX6Xxdc0C76DobER588cwG+J2tvbEHQlQ=";
  };
  postPatch = "";
  buildInputs = with pkgs; [
    bzip2
    zlib
    gcc
    gnumake
    elfutils
    xz
  ];
  buildPhase = ''
    make LINKTYPE=dynamic -j$NIX_BUILD_CORES
  '';
  installPhase = ''
    mkdir -p $out/bin $out/share/man/man{5,8}
    install -m 755 -t $out/bin makedumpfile
    install -m 644 -t $out/share/man/man5 makedumpfile.conf.5
    install -m 644 -t $out/share/man/man8 makedumpfile.8
  '';
  fixupPhase = ''
    patchShebangs $out/${name}/*
  '';
}

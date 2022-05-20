{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "makedumpfile";
  src = fetchFromGitHub {
    owner = "makedumpfile";
    repo = "makedumpfile";
    rev = "09b5c879b9f787c52f1963555d8d46127c457f2a";
    sha256 = "sha256-RJ1Rcfp5d1fYt45cJ4/fR9PxnaakoNEkESPrJFKOHSY=";
  };
  postPatch = ''
  '';
  buildInputs = with pkgs; [
    bzip2
    zlib
    lzma
    gnumake
    elfutils
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

{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "makedumpfile";
  src = fetchFromGitHub {
    owner = "makedumpfile";
    repo = "makedumpfile";
    rev = "97a89484e2c960dd64933e1cea7a7248138f8a76";
    sha256 = "sha256-k9L7+OxY0wR6hByBjTkE7wj/Ow4IMH3OfhAuehW9q04=";
  };
  postPatch = ''
  '';
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

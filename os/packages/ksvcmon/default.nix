{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "ksvcmon";
  src = fetchFromGitHub {
    owner = "snajpa";
    repo = "ksvcmon";
    rev = "3c6cc3077dca58f74162bf8148c5988d3c0c14f3";
    sha256 = "sha256-HQRmXJ+JF8Ga1eMSlJpUgAuaZS3Gw3nwJPd7nev/8vk=";
  };
  postPatch = ''
  '';
  buildInputs = with pkgs; [
    libmicrohttpd
  ];
  buildPhase = ''
    make -j$NIX_BUILD_CORES
  '';
  installPhase = ''
    mkdir -p $out/bin
    install -m 755 -t $out/bin ksvcmon
  '';
}

{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "irq_heatmap";
  version = "1.3";
  src = fetchFromGitHub {
    owner = "snajpa";
    repo = "irq_heatmap";
    rev = "044a6a97dc2d8b0d16211105b8e208136257f900";
    sha256 = "sha256-2a2rmW9k5Ha+cEDXCHtU1QSAqL0w4EyVZbEUhXWyh2o=";
  };
  buildInputs = with pkgs; [
    gnumake numactl
  ];
  buildPhase = ''
    make -j$NIX_BUILD_CORES
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp ${name} $out/bin/${name}
  '';
}

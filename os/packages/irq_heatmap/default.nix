{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "irq_heatmap";
  version = "1.3";
  src = fetchFromGitHub {
    owner = "snajpa";
    repo = "irq_heatmap";
    rev = "357eb7f2d8302c97bf7d889fa1a89045016fed7f";
    sha256 = "sha256-4ERfs/uipdRjr/ScnvwOXj/q6TtFM6QaAEf9JgcVacI=";
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

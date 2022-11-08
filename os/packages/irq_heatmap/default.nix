{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "irq_heatmap";
  version = "0.git";
  src = fetchFromGitHub {
    owner = "andyphillips";
    repo = "irq_heatmap";
    rev = "0bd0857a3d7b3b33f33732ab9f880d25fa758a2a";
    sha256 = "sha256-uH9iZHB8CGqk74t1QL+YruQsdsRupZBOmLCIVTf1lvY=";
  };
  postPatch = ''
    substituteInPlace ./irq_numa.h --replace "define MAX_SOCKETS 4" "define MAX_SOCKETS 64"
    substituteInPlace ./irq_numa.h --replace "define MAX_CORES 64" "define MAX_CORES 256"
  '';
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

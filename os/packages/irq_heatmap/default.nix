{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "irq_heatmap";
  version = "0.git";
  src = fetchFromGitHub {
    owner = "snajpa";
    repo = "irq_heatmap";
    rev = "bde047b57da70134028e28b769ef4efc49f3e7a2";
    sha256 = "sha256-9o8zy7PmXxOuoUfjWkG0MzRkNRY/CCkJj+Fi30ADTqs=";
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

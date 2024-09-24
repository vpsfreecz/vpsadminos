{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "kpatch-build";
  version = "0.9.9";
  src = fetchFromGitHub {
    owner = "dynup";
    repo = "kpatch";
    rev = "2f6a812a5f985750a85ede565b21375e6a468d1b";
    sha256 = "sha256-+Rcz5XeNsb7RQCVE1ca32GjV5rGxxeKAkZqIA9Uf2/o=";
  };
  postPatch = ''
    substituteInPlace ./kpatch-build/kpatch-build --replace /bin/bash "${pkgs.bashInteractive}/bin/bash"
    substituteInPlace ./kpatch-build/kpatch-build --replace "getopt" "${getopt}/bin/getopt"
    substituteInPlace ./kpatch-build/kpatch-build --replace "DEBUG=0" 'DEBUG="''${DEBUG:-3}"'
    substituteInPlace ./kpatch-build/kpatch-build --replace "../patch/tmp_output.o" "\$TEMPDIR/patch/tmp_output.o"
  '';
  buildInputs = with pkgs; [
    gnumake
    elfutils
  ];
  buildPhase = ''
    make -j$NIX_BUILD_CORES
  '';
  installPhase = ''
    mkdir -p $out/${name}
    cp kpatch-build/kpatch-{build,cc} $out/${name}/
    cp kpatch-build/create-diff-object $out/${name}/
    cp kpatch-build/create-klp-module $out/${name}/
    cp -r kpatch-build/gcc-plugins $out/${name}/
    cp -r kmod $out/
  '';
  fixupPhase = ''
    patchShebangs $out/${name}/*
  '';
}

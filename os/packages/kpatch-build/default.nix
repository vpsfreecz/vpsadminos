{ pkgs, getopt, fetchFromGitHub, ... }:
pkgs.stdenv.mkDerivation rec {
  name = "kpatch-build";
  version = "0.9.9";
  src = fetchFromGitHub {
    owner = "snajpa";
    repo = "kpatch";
    rev = "b3a3ef1f730554faae2e8ff04459e4eaf271e8fb";
    sha256 = "sha256-xM92sy2h29KlYDmuwjnStnN+lP87TEdxPVkkEuMJ9DM=";
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

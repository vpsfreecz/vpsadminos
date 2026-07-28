{
  pkgs,
  getopt,
  fetchFromGitHub,
  ...
}:
pkgs.stdenv.mkDerivation rec {
  name = "kpatch-build";
  version = "0.9.11";
  src = fetchFromGitHub {
    owner = "dynup";
    repo = "kpatch";
    rev = "bea635fbbeb11c5f0f5c0d4ffce34c2e9d2e8a6a";
    sha256 = "sha256-bVoNNtzNGCd1+8RmxDeLPr/6g4KdYmDFuCmJYET5AIU=";
  };
  patches = [
    ./0001-kpatch-build-register-system-states.patch
    ./0002-kpatch-build-group-module-targets.patch
    ./0003-kpatch-build-sort-diff-objects.patch
  ];
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

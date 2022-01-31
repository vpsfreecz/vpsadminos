{ lib, stdenv, pkgs, fetchFromGitHub }:
let
  kernel = pkgs.callPackage (import ../../linux/default.nix) {};
in
stdenv.mkDerivation rec {
  pname = "livepatch-${kernel.modDirVersion}-fakecpu-mask";
  version = "1";
  src = ./.;

  buildPhase = ''
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
      -j$NIX_BUILD_CORES M=$(pwd) modules
  '';

  installPhase = ''
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build  \
      INSTALL_MOD_PATH=$out M=$(pwd) modules_install
  '';

}

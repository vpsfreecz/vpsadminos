{ bundlerEnv, ruby, stdenv, lib }:
let
  env = bundlerEnv {
    name = "osctl-exporter";
    gemdir = ./.;
    inherit ruby;
  };
in stdenv.mkDerivation rec {
  name = "osctl-exporter-${version}";
  version = (import ./gemset.nix).osctl-exporter.version;
  src = ../../../osctl-exporter;

  buildInputs = [ env ];
  phases = [ "installPhase" "fixupPhase" ];
  installPhase = ''
    mkdir -p $out
    ln -sf ${env} $out/env
    cp -p ${src}/config.ru $out/config.ru
  '';

  passthru = {
    inherit env ruby;
  };

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

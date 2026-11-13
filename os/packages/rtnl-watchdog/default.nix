{ lib, stdenv }:
stdenv.mkDerivation {
  pname = "rtnl-watchdog";
  version = "1";
  src = lib.cleanSourceWith {
    src = ../../../rtnl-watchdog;
    filter = path: _type: builtins.baseNameOf path != "build";
  };
  makeFlags = [
    "CC=${stdenv.cc.targetPrefix}cc"
    "PREFIX=$(out)"
  ];
  enableParallelBuilding = true;
  doCheck = true;
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/rtnl-watchdog --help >/dev/null
    $out/bin/rtnl-watchdog --version >/dev/null
    runHook postInstallCheck
  '';
  meta = {
    description = "Active global RTNL-path responsiveness watchdog";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "rtnl-watchdog";
  };
}

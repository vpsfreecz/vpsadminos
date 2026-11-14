{ lib, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "rtnl-watchdog";
  version = "1.0.0";
  src = lib.cleanSource ../../../rtnl-watchdog;
  cargoLock.lockFile = ../../../rtnl-watchdog/Cargo.lock;
  cargoTestFlags = [ "--all-targets" ];
  postInstall = ''
    mkdir -p $out/libexec
    mv $out/bin/rtnl-watchdog-probe $out/libexec/rtnl-watchdog-probe
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/rtnl-watchdog --help >/dev/null
    $out/bin/rtnl-watchdog --version >/dev/null
    test -x $out/libexec/rtnl-watchdog-probe
    test ! -e $out/bin/rtnl-watchdog-probe
    runHook postInstallCheck
  '';
  meta = {
    description = "Active global RTNL-path responsiveness watchdog";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "rtnl-watchdog";
  };
}

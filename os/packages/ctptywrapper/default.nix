{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "ctptywrapper";
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../../../.version);

  src = ../../../ctptywrapper;

  cargoLock = {
    lockFile = ../../../ctptywrapper/Cargo.lock;
  };

  meta = with lib; {
    description = "Container PTY wrapper for vpsAdminOS";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

{ mkDerivation, atomic-write, attoparsec, base, bytestring
, config-ini, containers, data-prometheus, dns, fetchgit, hspec
, iproute, pretty-simple, process, stdenv, text
}:
mkDerivation {
  pname = "machine-check";
  version = "0.1.0.0";
  src = fetchgit {
    url = "https://github.com/vpsfreecz/machine-check";
    sha256 = "1b9g5w9xz4bbgy4frggg6qjkb17y490rpdcrn7l51y3a20bdv03a";
    rev = "740e0ba38b83f5af78597e3e35b7ceafbe070326";
    fetchSubmodules = true;
  };
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    atomic-write attoparsec base bytestring config-ini containers
    data-prometheus dns iproute pretty-simple process text
  ];
  executableHaskellDepends = [ base bytestring pretty-simple ];
  testHaskellDepends = [ attoparsec base hspec text ];
  homepage = "https://github.com/vpsfreecz/machine-check";
  description = "Linux system checks";
  license = stdenv.lib.licenses.bsd3;
}

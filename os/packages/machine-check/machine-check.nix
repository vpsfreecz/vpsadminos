{ mkDerivation, atomic-write, attoparsec, base, bytestring
, containers, data-prometheus, fetchgit, hspec, pretty-simple
, process, stdenv, text
}:
mkDerivation {
  pname = "machine-check";
  version = "0.1.0.0";
  src = fetchgit {
    url = "https://github.com/vpsfreecz/machine-check";
    sha256 = "066b12dnlvwa97bf3hprckcwh8vh5zlb4l3j7rnpx7hwasrwkvpm";
    rev = "36f88b6e24fa59b8f4c27f410b2381945acdf7af";
    fetchSubmodules = true;
  };
  isLibrary = false;
  isExecutable = true;
  enableSharedExecutables = false;
  enableSharedLibraries = false;
  libraryHaskellDepends = [
    atomic-write attoparsec base bytestring containers data-prometheus
    pretty-simple process text
  ];
  executableHaskellDepends = [ base bytestring pretty-simple ];
  testHaskellDepends = [ attoparsec base hspec text ];
  homepage = "https://github.com/vpsfreecz/machine-check";
  description = "Linux system checks";
  license = stdenv.lib.licenses.bsd3;
}

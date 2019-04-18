{ mkDerivation, attoparsec, base, bytestring, containers, fetchgit
, hspec, lens, raw-strings-qq, stdenv, transformers, wreq
}:
mkDerivation {
  pname = "data-prometheus";
  version = "0.1.0.0";
  src = fetchgit {
    url = "https://github.com/vpsfreecz/data-prometheus";
    sha256 = "06xmcn27agi1vjbw9jvd2r27lnqnb958vmf6wa13xjkmn4k3qp3v";
    rev = "baf7779db12be3b96645cbbf12102d238fbd188e";
    fetchSubmodules = true;
  };
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    attoparsec base bytestring containers transformers wreq
  ];
  executableHaskellDepends = [
    attoparsec base bytestring lens wreq
  ];
  testHaskellDepends = [
    attoparsec base containers hspec raw-strings-qq
  ];
  homepage = "https://github.com/vpsfreecz/data-prometheus";
  description = "Prometheus metrics data types and parser";
  license = stdenv.lib.licenses.bsd3;
}

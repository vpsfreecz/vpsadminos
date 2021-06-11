{ mkDerivation, attoparsec, base, bytestring, containers, fetchgit
, hspec, lens, raw-strings-qq, lib, transformers, wreq
}:
mkDerivation {
  pname = "data-prometheus";
  version = "0.1.0.0";
  src = fetchgit {
    url = "https://github.com/vpsfreecz/data-prometheus";
    sha256 = "17f8dbyis1wgsqsgsyiz2lsg7hik51lcrw8kyv4lcnijjnyzqbf3";
    rev = "cc0125074d8d7053be61392458a4b476dc866134";
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
  license = lib.licenses.bsd3;
}

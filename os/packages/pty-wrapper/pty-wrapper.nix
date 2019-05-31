{ mkDerivation, aeson, async, base, base64-bytestring, bytestring
, fetchgit, network, posix-pty, stdenv, stm, text
}:
mkDerivation {
  pname = "pty-wrapper";
  version = "0.1.0.0";
  src = fetchgit {
    url = "https://github.com/vpsfreecz/pty-wrapper";
    sha256 = "0fs91qqx47i4inlwp2q8kzli9gnrn40gmdb31p987wmqxqykqmwg";
    rev = "568daa80ed2d223209946bc2be5f585a74a3cd32";
    fetchSubmodules = true;
  };
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson async base base64-bytestring bytestring network posix-pty stm
    text
  ];
  executableHaskellDepends = [ base bytestring ];
  homepage = "https://github.com/vpsfreecz/pty-wrapper";
  description = "PTY wrapper";
  license = stdenv.lib.licenses.bsd3;
}

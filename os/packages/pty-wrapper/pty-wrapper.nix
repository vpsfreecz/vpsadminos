{ mkDerivation, aeson, async, base, base64-bytestring, bytestring
, fetchgit, network, posix-pty, stdenv, stm, text
}:
mkDerivation {
  pname = "pty-wrapper";
  version = "0.1.0.0";
  src = fetchgit {
    url = "https://github.com/vpsfreecz/pty-wrapper";
    sha256 = "1cxyrf7sghsjqjhiv7pads1ifqmg31swcqfiz3dhf2cnb2bjh3lh";
    rev = "b30f65e013dc0c6db7e34e2795870339ccf45ac6";
    fetchSubmodules = true;
  };
  isLibrary = false;
  isExecutable = true;
  enableSharedExecutables = false;
  enableSharedLibraries = false;
  libraryHaskellDepends = [
    aeson async base base64-bytestring bytestring network posix-pty stm
    text
  ];
  executableHaskellDepends = [ base bytestring ];
  homepage = "https://github.com/vpsfreecz/pty-wrapper";
  description = "PTY wrapper";
  license = stdenv.lib.licenses.bsd3;
}

{ fetchFromGitHub, lib, ruby, stdenvNoCC, substituteAll }:
let
  rev = "566be0e2d23e0ecb144e16b1bb422d2473a367a6";
  shortRev = builtins.substring 0 7 rev;
in stdenvNoCC.mkDerivation {
  pname = "scrubctl";
  version = shortRev;

  src = fetchFromGitHub {
    owner = "vpsfreecz";
    repo = "scrubctl";
    inherit rev;
    sha256 = "sha256:1nb9zhrjpfr4l8am8pl1qj3y4x3z0nsc9rasgbsmm719hgs8iksl";
  };

  buildInputs = [
    ruby
  ];

  patchPhase = ''
    patchShebangs bin/*
  '';

  dontBuild = true;

  installPhase = ''
    install -Dm755 -t $out/bin bin/scrubctl
  '';

  meta = with lib; {
    description = "zpool scrub control";
    homepage = "https://github.com/vpsfreecz/scrubctl";
    license = licenses.mit;
    platforms = platforms.all;
    maintainers = with maintainers; [];
  };
}

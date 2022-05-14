{ lib
, stdenv
, fetchFromGitHub
, cmake
, meson
, ninja
}:
let
  revision = "80f769e3ec80d9f8376a8985f8c31912c075181e";

  osbench = fetchFromGitHub {
    owner = "vpsfreecz";
    repo = "osbench";
    rev = revision;
    sha256 = "sha256:09xy8487w830ihp3rznbnqvygwp8fw5ij6136vjm7w6xgqhji5vn";
  };
in stdenv.mkDerivation rec {
  pname = "osbench";
  version = lib.substring 0 7 revision;

  src = "${osbench}/src";

  nativeBuildInputs = [ meson ninja ];

  installPhase = ''
    mkdir -p $out/bin
    find -type f -executable -exec install -m 0555 {} $out/bin/{} \;
  '';

  meta = with lib; {
    homepage = "https://github.com/vpsfreecz/osbench";
    description = "Benchmarking tools for measuring operating system performance";
    maintainers = [];
    platforms = platforms.unix;
    license = licenses.unlicense;
  };
}

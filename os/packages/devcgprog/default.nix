{ lib, buildGoModule, fetchFromGitHub }:
let
  rev = "0ace4c99df64f27d278be4b3852fd9988bb123c5";
in buildGoModule {
  pname = "devcgprog";
  version = lib.substring 0 7 rev;

  src = fetchFromGitHub {
    owner = "vpsfreecz";
    repo = "devcgprog";
    inherit rev;
    sha256 = "sha256-a7EA094ESZZzXJi+5ehV5MN860u1KUS2o494N/zruqE=";
  };

  vendorHash = "sha256-jqEaopGSiLxngEKNX8j2erzMS4+I9RWcH9+Fd9O9uss=";

  meta = with lib; {
    description = "Tool to configure cgroupv2 device controller";
    homepage    = https://github.com/vpsfreecz/devcgprog;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

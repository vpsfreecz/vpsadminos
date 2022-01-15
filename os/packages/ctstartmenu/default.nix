{ lib, buildGoModule }:

buildGoModule {
  pname = "ctstartmenu";
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../../../.version);

  src = ../../../ctstartmenu;

  vendorSha256 = "sha256:0b6abzpbf4j2mlizwqdhf4769sxwd9m0di77x2f13sxdl4a0bcam";

  meta = with lib; {
    description = "Start menu for containers";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

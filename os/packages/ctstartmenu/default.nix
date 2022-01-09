{ lib, buildGoModule }:

buildGoModule {
  pname = "ctstartmenu";
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../../../.version);

  src = ../../../ctstartmenu;

  vendorSha256 = "sha256:139apy95g69dzbmwiqyc67mrqs0mqndnsrfx42dhx4xzq13xp0m1";

  meta = with lib; {
    description = "Start menu for containers";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

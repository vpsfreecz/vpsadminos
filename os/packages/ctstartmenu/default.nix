{ lib, buildGoModule }:

buildGoModule {
  pname = "ctstartmenu";
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../../../.version);

  src = ../../../ctstartmenu;

  vendorHash = "sha256-e4w0YHxa/ImM3DseWCugbuytn5TNY8MIO69Dl7B0vpc=";

  meta = with lib; {
    description = "Start menu for containers";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

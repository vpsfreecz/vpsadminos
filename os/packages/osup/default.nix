{ lib, osBundlerApp }:

osBundlerApp {
  pname = "osup";
  gemdir = ./.;
  exes = [ "osup" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

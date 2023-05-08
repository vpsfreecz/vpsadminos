{ lib, osBundlerApp }:

osBundlerApp {
  pname = "osup";
  gemdir = ./.;
  exes = [ "osup" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

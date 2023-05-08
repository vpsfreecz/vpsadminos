{ lib, osBundlerApp }:

osBundlerApp {
  pname = "osup";
  gemdir = ./.;
  exes = [ "osup" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

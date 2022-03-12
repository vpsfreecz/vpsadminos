{ lib, osBundlerApp }:

osBundlerApp {
  pname = "svctl";
  gemdir = ./.;
  exes = [ "svctl" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

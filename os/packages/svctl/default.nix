{ lib, osBundlerApp }:

osBundlerApp {
  pname = "svctl";
  gemdir = ./.;
  exes = [ "svctl" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

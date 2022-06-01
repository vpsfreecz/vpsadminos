{ lib, bundlerApp }:

bundlerApp {
  pname = "osvm";
  gemdir = ./.;
  exes = [ "osvm" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

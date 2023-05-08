{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctld";
  gemdir = ./.;
  exes = [ "osctld" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

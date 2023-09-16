{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctld";
  gemdir = ./.;
  exes = [ "osctld" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

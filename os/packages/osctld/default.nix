{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctld";
  gemdir = ./.;
  exes = [ "osctld" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

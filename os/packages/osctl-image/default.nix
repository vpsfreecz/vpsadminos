{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctl-image";
  gemdir = ./.;
  exes = [ "osctl-image" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

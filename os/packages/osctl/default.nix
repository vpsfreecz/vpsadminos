{ lib, osBundlerApp }:

osBundlerApp {
  pname = "osctl";
  gemdir = ./.;
  exes = [ "osctl" "ct" "group" "healthcheck" "id-range" "pool" "repo" "user" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

{ lib, osBundlerApp }:

osBundlerApp {
  pname = "osctl";
  gemdir = ./.;
  exes = [ "osctl" "ct" "group" "healthcheck" "id-range" "pool" "repo" "user" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

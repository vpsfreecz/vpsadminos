{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctl-image";
  gemdir = ./.;
  exes = [ "osctl-image" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

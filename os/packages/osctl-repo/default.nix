{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctl-repo";
  gemdir = ./.;
  exes = [ "osctl-repo" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

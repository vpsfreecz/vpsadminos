{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctl-exportfs";
  gemdir = ./.;
  exes = [ "osctl-exportfs" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

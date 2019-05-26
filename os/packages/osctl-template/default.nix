{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctl-template";
  gemdir = ./.;
  exes = [ "osctl-template" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [ maintainers.sorki ];
    platforms   = platforms.unix;
  };
}

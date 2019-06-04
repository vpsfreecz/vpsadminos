{ pkgs, lib, bundlerApp }:

bundlerApp {
  pname = "osctl-repo";
  gemdir = ./.;
  exes = [ "osctl-repo" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [ maintainers.sorki ];
    platforms   = platforms.unix;
  };
}

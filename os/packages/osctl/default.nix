{ lib, bundlerApp }:

bundlerApp {
  pname = "osctl";
  gemdir = ./.;
  exes = [ "osctl" ];
  manpages = [ "man8/osctl.8" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [ maintainers.sorki ];
    platforms   = platforms.unix;
  };
}

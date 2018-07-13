{ lib, bundlerApp }:

bundlerApp {
  pname = "osup";
  gemdir = ./.;
  exes = [ "osup" ];
  manpages = [ "man8/osup.8" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [ maintainers.sorki ];
    platforms   = platforms.unix;
  };
}

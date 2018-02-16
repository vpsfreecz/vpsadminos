{ lib, bundlerApp }:

bundlerApp {
  pname = "osctl-env-exec";
  gemdir = ./.;
  exes = [ "osctl-env-exec" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [ maintainers.sorki ];
    platforms   = platforms.unix;
  };
}

{ lib, bundlerApp }:

bundlerApp {
  pname = "svctl";
  gemdir = ./.;
  exes = [ "svctl" ];
  manpages = [ "man8/svctl.8" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

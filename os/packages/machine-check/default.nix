{ lib, bundlerApp }:

bundlerApp {
  pname = "machine-check";
  gemdir = ./.;
  exes = [ "machine-check" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/machine-check-rb;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

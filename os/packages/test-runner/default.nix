{ lib, bundlerApp }:

bundlerApp {
  pname = "test-runner";
  gemdir = ./.;
  exes = [ "test-runner" ];

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

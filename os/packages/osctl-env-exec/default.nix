{ lib, bundlerApp }:

bundlerApp {
  pname = "osctl-env-exec";
  gemdir = ./.;
  exes = [ "osctl-env-exec" ];
  gemConfig = {
    binman = attrs: {
      dontInstallManpages = true;
    };
  };

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.asl20;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

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
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

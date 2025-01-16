{ lib, bundlerApp, defaultGemConfig }:

bundlerApp {
  pname = "osctl-env-exec";
  gemdir = ./.;
  exes = [ "osctl-env-exec" ];
  gemConfig = lib.mergeAttrs defaultGemConfig {
    binman = attrs: {
      dontInstallManpages = true;
    };
  };

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadminos;
    license     = licenses.mit;
    maintainers = [];
    platforms   = platforms.unix;
  };
}

{
  lib,
  bundlerApp,
  defaultGemConfig,
  ruby,
  gemConfig ? defaultGemConfig,
}:

bundlerApp {
  pname = "osctl-env-exec";
  gemdir = ./.;
  inherit ruby;
  exes = [ "osctl-env-exec" ];
  gemConfig = lib.mergeAttrs gemConfig {
    binman = attrs: {
      dontInstallManpages = true;
    };
  };

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

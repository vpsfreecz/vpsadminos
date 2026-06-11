{
  lib,
  osBundlerApp,
  ruby,
  defaultGemConfig,
  gemConfig ? defaultGemConfig,
}:

osBundlerApp {
  pname = "svctl";
  gemdir = ./.;
  inherit ruby;
  inherit gemConfig;
  exes = [ "svctl" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

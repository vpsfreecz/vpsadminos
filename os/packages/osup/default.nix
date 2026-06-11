{
  lib,
  osBundlerApp,
  ruby,
  defaultGemConfig,
  gemConfig ? defaultGemConfig,
}:

osBundlerApp {
  pname = "osup";
  gemdir = ./.;
  inherit ruby;
  inherit gemConfig;
  exes = [ "osup" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

{
  lib,
  bundlerApp,
  ruby,
  defaultGemConfig,
  gemConfig ? defaultGemConfig,
}:

bundlerApp {
  pname = "osvm";
  gemdir = ./.;
  inherit ruby;
  inherit gemConfig;
  exes = [ "osvm" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

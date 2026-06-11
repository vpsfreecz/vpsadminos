{
  pkgs,
  lib,
  bundlerApp,
  ruby,
  defaultGemConfig,
  gemConfig ? defaultGemConfig,
}:

bundlerApp {
  pname = "osctl-oomd";
  gemdir = ./.;
  inherit ruby;
  inherit gemConfig;
  exes = [ "osctl-oomd" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

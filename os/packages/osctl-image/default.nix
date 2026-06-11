{
  pkgs,
  lib,
  bundlerApp,
  ruby,
  defaultGemConfig,
  gemConfig ? defaultGemConfig,
}:

bundlerApp {
  pname = "osctl-image";
  gemdir = ./.;
  inherit ruby;
  inherit gemConfig;
  exes = [ "osctl-image" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

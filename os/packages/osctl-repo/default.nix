{
  pkgs,
  lib,
  bundlerApp,
  ruby,
  defaultGemConfig,
  gemConfig ? defaultGemConfig,
}:

bundlerApp {
  pname = "osctl-repo";
  gemdir = ./.;
  inherit ruby;
  inherit gemConfig;
  exes = [ "osctl-repo" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

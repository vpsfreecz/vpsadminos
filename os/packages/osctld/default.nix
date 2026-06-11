{
  pkgs,
  lib,
  bundlerApp,
  ruby,
  defaultGemConfig,
  gemConfig ? defaultGemConfig,
}:

bundlerApp {
  pname = "osctld";
  gemdir = ./.;
  inherit ruby;
  inherit gemConfig;
  exes = [ "osctld" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

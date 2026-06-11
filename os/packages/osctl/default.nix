{
  lib,
  osBundlerApp,
  ruby,
  defaultGemConfig,
  gemConfig ? defaultGemConfig,
}:

osBundlerApp {
  pname = "osctl";
  gemdir = ./.;
  inherit ruby;
  inherit gemConfig;
  exes = [
    "osctl"
    "ct"
    "group"
    "healthcheck"
    "id-range"
    "pool"
    "repo"
    "user"
  ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

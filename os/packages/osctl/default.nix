{
  lib,
  osBundlerApp,
  ruby,
}:

osBundlerApp {
  pname = "osctl";
  gemdir = ./.;
  inherit ruby;
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

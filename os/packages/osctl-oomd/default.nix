{
  pkgs,
  lib,
  bundlerApp,
  ruby,
}:

bundlerApp {
  pname = "osctl-oomd";
  gemdir = ./.;
  inherit ruby;
  exes = [ "osctl-oomd" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

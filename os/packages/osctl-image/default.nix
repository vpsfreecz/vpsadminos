{
  pkgs,
  lib,
  bundlerApp,
  ruby,
}:

bundlerApp {
  pname = "osctl-image";
  gemdir = ./.;
  inherit ruby;
  exes = [ "osctl-image" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

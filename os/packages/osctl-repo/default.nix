{
  pkgs,
  lib,
  bundlerApp,
  ruby,
}:

bundlerApp {
  pname = "osctl-repo";
  gemdir = ./.;
  inherit ruby;
  exes = [ "osctl-repo" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

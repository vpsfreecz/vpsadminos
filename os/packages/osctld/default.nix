{
  pkgs,
  lib,
  bundlerApp,
  ruby,
}:

bundlerApp {
  pname = "osctld";
  gemdir = ./.;
  inherit ruby;
  exes = [ "osctld" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

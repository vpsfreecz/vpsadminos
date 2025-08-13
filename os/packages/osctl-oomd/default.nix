{
  pkgs,
  lib,
  bundlerApp,
}:

bundlerApp {
  pname = "osctl-oomd";
  gemdir = ./.;
  exes = [ "osctl-oomd" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

{
  lib,
  bundlerApp,
  ruby,
}:

bundlerApp {
  pname = "osvm";
  gemdir = ./.;
  inherit ruby;
  exes = [ "osvm" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

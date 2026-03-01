{
  lib,
  osBundlerApp,
  ruby,
}:

osBundlerApp {
  pname = "osup";
  gemdir = ./.;
  inherit ruby;
  exes = [ "osup" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

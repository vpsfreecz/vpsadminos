{
  lib,
  osBundlerApp,
  ruby,
}:

osBundlerApp {
  pname = "svctl";
  gemdir = ./.;
  inherit ruby;
  exes = [ "svctl" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

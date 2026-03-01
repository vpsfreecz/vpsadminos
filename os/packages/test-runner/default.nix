{
  lib,
  bundlerApp,
  ruby,
}:

bundlerApp {
  pname = "test-runner";
  gemdir = ./.;
  inherit ruby;
  exes = [ "test-runner" ];

  meta = with lib; {
    description = "";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.unix;
  };
}

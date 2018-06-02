{ pkgs, lib, bundlerApp, defaultGemConfig }:

bundlerApp {
  pname = "osctld";
  gemdir = ./.;
  exes = [ "osctld" ];
  gemConfig = lib.mergeAttrs defaultGemConfig {
    osctld = attrs: {
      buildInputs = [ pkgs.apparmor-parser ];
    };
  };

  meta = with lib; {
    description = "";
    homepage    = https://github.com/vpsfreecz/vpsadmin;
    license     = licenses.gpl3;
    maintainers = [ maintainers.sorki ];
    platforms   = platforms.unix;
  };
}

{ lib, buildGoModule }:

buildGoModule {
  pname = "osctl-repo-server";
  version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ../../../.version);
  src = ../../../osctl-repo-server;
  vendorHash = "sha256-Swi56SaPh4AN7LZ2a+j3p/jNf/InnbmE6AEErjqLg0g=";
  subPackages = [ "cmd/osctl-repo-server" ];
  doCheck = true;
  meta = with lib; {
    description = "Public and run-scoped container image repository service";
    homepage = "https://github.com/vpsfreecz/vpsadminos";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "osctl-repo-server";
  };
}

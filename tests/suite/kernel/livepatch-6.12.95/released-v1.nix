{
  system ? builtins.currentSystem,
}:

let
  flake = builtins.getFlake (toString ../../../..);
  evaluated = flake.lib.vpsadminosSystem {
    inherit system;
    modules = [
      {
        boot.kernelVersion = "6.12.95";
        services.live-patches.enable = true;
      }
    ];
  };
  pkgs = evaluated.pkgs;
  base = evaluated.config.system.build.livePatches;
  source = pkgs.runCommand "livepatches-released-v1" { } ''
    mkdir "$out"
    cp ${./bp-6.12.95-released-v1.patch} \
      "$out/bp-6.12.95-released-v1.patch"
  '';
in
base.overrideAttrs (old: {
  name = "livepatch_1-6.12.95";
  inherit source;
  src = source;
  buildPhase =
    builtins.replaceStrings
      [
        ''#define LIVEPATCH_NAME                       "2"''
        "livepatch_2"
        "bp-6.12.95-cumulative.patch"
      ]
      [
        ''#define LIVEPATCH_NAME                       "1"''
        "livepatch_1"
        "bp-6.12.95-released-v1.patch"
      ]
      old.buildPhase;
  installPhase = builtins.replaceStrings [ "livepatch_2" ] [ "livepatch_1" ] old.installPhase;
})

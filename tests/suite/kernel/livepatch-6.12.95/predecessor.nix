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
  source = pkgs.runCommand "livepatches-predecessor-v4" { } ''
    mkdir "$out"
    cp ${./bp-6.12.95-predecessor-v4.patch} \
      "$out/bp-6.12.95-predecessor-v4.patch"
  '';
in
base.overrideAttrs (old: {
  name = "livepatch_predecessor_1-6.12.95";
  inherit source;
  src = source;
  buildPhase =
    builtins.replaceStrings
      [
        ''#define LIVEPATCH_NAME                       "2"''
        "livepatch_2"
        "bp-6.12.95-cumulative.patch"
        " $src/bp-6.12.95-uname.patch"
        " bp-6.12.95-uname.patch"
      ]
      [
        ''#define LIVEPATCH_NAME                       "predecessor_1"''
        "livepatch_predecessor_1"
        "bp-6.12.95-predecessor-v4.patch"
        ""
        ""
      ]
      old.buildPhase;
  installPhase =
    builtins.replaceStrings [ "livepatch_2" ] [ "livepatch_predecessor_1" ]
      old.installPhase;
})

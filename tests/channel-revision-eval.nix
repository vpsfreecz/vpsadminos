# Run with nix eval --impure --raw --file tests/channel-revision-eval.nix.
# Evaluate the real channel derivation without copying sources or building a VM.
let
  nixpkgsPath =
    let
      env = builtins.getEnv "TEST_RUNNER_NIXPKGS_PATH";
    in
    if env != "" then
      builtins.toPath env
    else
      (builtins.getFlake (toString ../.)).inputs.nixpkgs.outPath;
  pkgs = import nixpkgsPath { };
  inherit (pkgs) lib;
  versionOptions =
    (import ../os/modules/misc/version.nix {
      inherit lib;
      config = { };
      pkgs = { };
    }).options.system.vpsadminos;
  checkChannel =
    revision: expectedRevisionWrites:
    let
      evaluated = lib.evalModules {
        specialArgs = {
          inherit nixpkgsPath;
          pkgs = pkgs // {
            runCommand =
              name: attrs: buildCommand:
              let
                channel = pkgs.runCommand name attrs buildCommand;
                revisionWrites = map lib.strings.trim (
                  lib.filter (lib.hasInfix ".git-revision") (lib.splitString "\n" buildCommand)
                );
              in
              if name == "vpsadminos-channel-revision-test" then
                assert lib.hasSuffix ".drv" channel.drvPath;
                assert revisionWrites == expectedRevisionWrites;
                channel
              else
                channel;
          };
        };
        modules = [
          ../os/modules/installer/cd-dvd/channel.nix
          {
            options = {
              system.vpsadminos = lib.getAttrs [
                "version"
                "release"
                "versionSuffix"
                "revision"
              ] versionOptions;
              runit.services = lib.mkOption { type = lib.types.attrs; };
            };
            config = {
              os.channel-registration.enable = true;
              system.vpsadminos = {
                inherit revision;
                version = "channel-revision-test";
                versionSuffix = ".git.test";
              };
            };
          }
        ];
      };
    in
    assert lib.hasInfix "channels/vpsadminos" evaluated.config.runit.services.channel-registration.run;
    true;
in
assert checkChannel null [ ];
assert checkChannel "0123456789abcdef0123456789abcdef01234567" [
  "echo -n 0123456789abcdef0123456789abcdef01234567 > $out/vpsadminos/.git-revision"
];
"channel derivations handle unknown and known revisions\n"

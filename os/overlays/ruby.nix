self: super:
{
  ruby = super.ruby_3_3.overrideAttrs (oldAttrs: rec {
    patches = oldAttrs.patches ++ [
      ../packages/ruby/export-timer-functions.patch
    ];
  });

  defaultGemConfig =
    super.callPackage (
      { lib, apparmor-parser }:

      lib.mergeAttrs super.defaultGemConfig {
        osctld = attrs: {
          buildInputs = [ apparmor-parser ];
        };
      }) {};

  bundix = super.bundix.overrideAttrs (oldAttrs: rec {
    name = "bundix-${version}";
    version = "master-1b7df693";
    src = super.fetchFromGitHub {
      owner = "nix-community";
      repo = "bundix";
      rev = "1b7df693f9660b4c27b16770b096094954c4aa9b";
      sha256 = "sha256-zJQKsC9sId+ui2wZ0nUaDRP1SmzrNTWoDJxUdLoATqI=";
    };
  });

  osBundlerApp = super.callPackage ../packages/os-bundler-app {};
}

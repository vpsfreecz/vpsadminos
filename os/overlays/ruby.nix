self: super:
let
  ruby_3_3 = super.ruby_3_3.overrideAttrs (oldAttrs: rec {
    patches = oldAttrs.patches ++ [
      ../packages/ruby/export-timer-functions.patch
    ];

    # Workaround for these warning messages:
    #
    #   Ignoring debug-1.9.2 because its extensions are not built. Try: gem pristine debug --version 1.9.2
    #   Ignoring racc-1.7.3 because its extensions are not built. Try: gem pristine racc --version 1.7.3
    #   Ignoring rbs-3.4.0 because its extensions are not built. Try: gem pristine rbs --version 3.4.0
    postFixup = ''
      rm $out/lib/ruby/gems/*/specifications/{debug*,rbs*,racc*}.gemspec
    '';
  });
in
{
  inherit ruby_3_3;

  ruby = ruby_3_3;

  defaultGemConfig = super.callPackage (
    { lib, apparmor-parser }:

    lib.mergeAttrs super.defaultGemConfig {
      osctld = attrs: {
        buildInputs = [ apparmor-parser ];
      };
    }
  ) { };

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

  osBundlerApp = super.callPackage ../packages/os-bundler-app { };
}

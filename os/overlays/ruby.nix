self: super:
let
  ruby_vpsadminos = super.ruby_3_4.overrideAttrs (oldAttrs: rec {
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
  inherit ruby_vpsadminos;

  defaultGemConfig = super.callPackage (
    { lib, apparmor-parser }:
    let
      localGemSrc = src:
        lib.cleanSourceWith {
          inherit src;
          filter = path: type:
            let
              name = baseNameOf path;
            in
            (lib.cleanSourceFilter path type)
            && !(type == "directory" && builtins.elem name [
              ".bundle"
              ".gems"
              "pkg"
              "tmp"
            ])
            && !(type == "symlink" && (name == "result" || lib.hasPrefix "result-" name))
            && !(lib.hasSuffix ".gem" name);
        };

      localGem = src: attrs:
        let
          buildIdMatch = builtins.match ".*\\.build([0-9]+)" attrs.version;
        in
        {
          src = localGemSrc src;
          env = (attrs.env or { }) // (
            if buildIdMatch == null then
              { }
            else
              { OS_BUILD_ID = builtins.elemAt buildIdMatch 0; }
          );
        };
    in

    lib.mergeAttrs super.defaultGemConfig {
      libosctl = localGem ../../libosctl;
      osctl-repo = localGem ../../osctl-repo;
      osctl = localGem ../../osctl;
      osctld = attrs: {
        buildInputs = (attrs.buildInputs or [ ]) ++ [ apparmor-parser ];
      } // localGem ../../osctld attrs;
      osup = localGem ../../osup;
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

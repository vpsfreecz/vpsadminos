{
  netlinkrb,
  ruby-lxc,
}:
self: super:
let
  lib = super.lib;
  rubyGemConfig = super.callPackage ../packages/ruby-source-gem-config.nix { };
  vpsadminosVersion = "${lib.removeSuffix "\n" (builtins.readFile ../../.version)}.0";
  sourceGemConfig =
    (rubyGemConfig.mkGemConfig {
      repoPath = ../../.;
      gems = {
        libosctl.version = vpsadminosVersion;
        osctl.version = vpsadminosVersion;
        osctl-exporter.version = vpsadminosVersion;
        osctl-exportfs.version = vpsadminosVersion;
        osctl-image.version = vpsadminosVersion;
        osctl-oomd.version = vpsadminosVersion;
        osctl-repo.version = vpsadminosVersion;
        osctld = {
          version = vpsadminosVersion;
          extraConfig = attrs: {
            buildInputs = (attrs.buildInputs or [ ]) ++ [ super.apparmor-parser ];
          };
        };
        osup.version = vpsadminosVersion;
        osvm.version = vpsadminosVersion;
        svctl.version = vpsadminosVersion;
        test-runner = {
          version = vpsadminosVersion;
          gemDir = "test-runner";
        };
        osctl-env-exec = {
          version = vpsadminosVersion;
          gemDir = "tools/osctl-env-exec";
        };
      };
    })
    // (rubyGemConfig.mkGemConfig {
      repoPath = netlinkrb;
      gems.netlinkrb = {
        version = "0.18.vpsadminos.0";
        gemDir = ".";
      };
    })
    // (rubyGemConfig.mkGemConfig {
      repoPath = ruby-lxc;
      gems.ruby-lxc = {
        version = "1.2.4.vpsadminos.6";
        gemDir = ".";
        extraConfig = attrs: {
          buildInputs = (attrs.buildInputs or [ ]) ++ [ super.lxc ];
        };
      };
    });
  vpsadminosRubyGemConfig = rubyGemConfig.mergeGemConfig super.defaultGemConfig sourceGemConfig;
in
{
  inherit vpsadminosRubyGemConfig;

  ctstartmenu = super.callPackage ../packages/ctstartmenu { };
  osctl = super.callPackage ../packages/osctl {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osctld = super.callPackage ../packages/osctld {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osup = super.callPackage ../packages/osup {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osctl-exporter = super.callPackage ../packages/osctl-exporter {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osctl-exportfs = super.callPackage ../packages/osctl-exportfs {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osctl-image = super.callPackage ../packages/osctl-image {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osctl-oomd = super.callPackage ../packages/osctl-oomd {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osctl-repo = super.callPackage ../packages/osctl-repo {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osctl-env-exec = super.callPackage ../packages/osctl-env-exec {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  osvm = super.callPackage ../packages/osvm {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  svctl = super.callPackage ../packages/svctl {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
  test-runner = super.callPackage ../packages/test-runner {
    ruby = self.ruby_vpsadminos;
    gemConfig = vpsadminosRubyGemConfig;
  };
}

self: super: {
  ctstartmenu = super.callPackage ../packages/ctstartmenu { };
  osctl = super.callPackage ../packages/osctl { ruby = self.ruby_vpsadminos; };
  osctld = super.callPackage ../packages/osctld { ruby = self.ruby_vpsadminos; };
  osup = super.callPackage ../packages/osup { ruby = self.ruby_vpsadminos; };
  osctl-exporter = super.callPackage ../packages/osctl-exporter { ruby = self.ruby_vpsadminos; };
  osctl-exportfs = super.callPackage ../packages/osctl-exportfs { ruby = self.ruby_vpsadminos; };
  osctl-image = super.callPackage ../packages/osctl-image { ruby = self.ruby_vpsadminos; };
  osctl-oomd = super.callPackage ../packages/osctl-oomd { ruby = self.ruby_vpsadminos; };
  osctl-repo = super.callPackage ../packages/osctl-repo { ruby = self.ruby_vpsadminos; };
  osctl-env-exec = super.callPackage ../packages/osctl-env-exec { ruby = self.ruby_vpsadminos; };
  osvm = super.callPackage ../packages/osvm { ruby = self.ruby_vpsadminos; };
  svctl = super.callPackage ../packages/svctl { ruby = self.ruby_vpsadminos; };
  test-runner = super.callPackage ../packages/test-runner { ruby = self.ruby_vpsadminos; };
}

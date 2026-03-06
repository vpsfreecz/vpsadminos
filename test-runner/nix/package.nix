{ pkgs }:
let
  ruby = pkgs.ruby_vpsadminos;
  deps = pkgs.bundlerEnv {
    name = "test-runner-deps";
    gemfile = ../../os/packages/test-runner/Gemfile;
    lockfile = ../../os/packages/test-runner/Gemfile.lock;
    gemset = ../../os/packages/test-runner/gemset.nix;
    groups = [ "default" ];
    inherit ruby;
  };

  testRunnerSrc = ../.;
  osvmSrc = ../../osvm;
  libosctlSrc = ../../libosctl;
in
pkgs.writeShellScriptBin "test-runner" ''
  export GEM_HOME=${deps}/${ruby.gemPath}
  export GEM_PATH=${deps}/${ruby.gemPath}
  export RUBYLIB=${testRunnerSrc}/lib:${osvmSrc}/lib:${libosctlSrc}/lib

  exec ${ruby}/bin/ruby ${testRunnerSrc}/bin/test-runner "$@"
''

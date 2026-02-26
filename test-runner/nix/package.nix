{ pkgs }:
let
  deps = pkgs.bundlerEnv {
    name = "test-runner-deps";
    gemdir = ../.;
    lockfile = ./Gemfile.lock.packaging;
    groups = [ "default" ];
  };

  testRunnerSrc = ../.;
  ruby = pkgs.ruby;
in
pkgs.writeShellScriptBin "test-runner" ''
  export GEM_HOME=${deps}/${ruby.gemPath}
  export GEM_PATH=${deps}/${ruby.gemPath}
  export RUBYLIB=${testRunnerSrc}/lib

  exec ${ruby}/bin/ruby ${testRunnerSrc}/bin/test-runner "$@"
''

{ pkgs }:
let
  ruby = pkgs.ruby_vpsadminos;
  deps = pkgs.bundlerEnv {
    name = "test-runner-deps";
    gemfile = ./Gemfile;
    lockfile = ./runner-deps.lock;
    gemset = ./gemset.nix;
    groups = [ "default" ];
    inherit ruby;
  };

  testRunnerSrc = ../.;
  osvmSrc = ../../osvm;
  libosctlSrc = ../../libosctl;
  libosctlNative = pkgs.stdenv.mkDerivation {
    pname = "libosctl-native";
    version = "local";
    src = libosctlSrc;
    nativeBuildInputs = [ ruby ];
    buildPhase = ''
      runHook preBuild
      cd ext/libosctl
      ruby extconf.rb
      make
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib/libosctl"
      install -m 755 native.so "$out/lib/libosctl/native.so"
      runHook postInstall
    '';
  };

  testRunnerWrapper = pkgs.writeShellScript "test-runner" ''
    export GEM_HOME=${deps}/${ruby.gemPath}
    export GEM_PATH=${deps}/${ruby.gemPath}
    export RUBYLIB=${testRunnerSrc}/lib:${osvmSrc}/lib:${libosctlSrc}/lib:${libosctlNative}/lib

    exec ${ruby}/bin/ruby ${testRunnerSrc}/bin/test-runner "$@"
  '';

  testJsonRunnerWrapper = pkgs.writeShellScript "test-json-runner" ''
    export GEM_HOME=${deps}/${ruby.gemPath}
    export GEM_PATH=${deps}/${ruby.gemPath}
    export RUBYLIB=${testRunnerSrc}/lib:${osvmSrc}/lib:${libosctlSrc}/lib:${libosctlNative}/lib

    exec ${ruby}/bin/ruby ${testRunnerSrc}/bin/test-json-runner "$@"
  '';
in
pkgs.runCommand "test-runner" { } ''
  mkdir -p "$out/bin"
  install -m 755 ${testRunnerWrapper} "$out/bin/test-runner"
  install -m 755 ${testJsonRunnerWrapper} "$out/bin/test-json-runner"
''

let
  pkgs = import <nixpkgs> { overlays = (import ../os/overlays); };
  stdenv = pkgs.stdenv;
  repoRoot = builtins.toString ../.;
  testRunnerRoot = "${repoRoot}/test-runner";
  gemHome = "${testRunnerRoot}/.gems";

in
stdenv.mkDerivation rec {
  name = "test-runner";

  buildInputs = with pkgs; [
    libffi
    git
    ruby
    zlib
  ];

  shellHook = ''
    export REPO_ROOT="${repoRoot}"
    export TEST_RUNNER_ROOT="${testRunnerRoot}"
    export GEM_HOME="${gemHome}"
    export GEM_PATH="$GEM_HOME:$TEST_RUNNER_ROOT/lib"
    export PATH="$GEM_HOME/bin:$PATH"

    mkdir -p "$GEM_HOME"

    BUNDLE="$GEM_HOME/bin/bundle"

    if [ ! -x "$BUNDLE" ]; then
      ${pkgs.ruby}/bin/gem install bundler --no-document
    fi

    export BUNDLE_PATH="$GEM_HOME"
    export BUNDLE_GEMFILE="$TEST_RUNNER_ROOT/Gemfile"

    # prism native extension needs relaxed purity for headers in GEM_HOME
    NIX_ENFORCE_PURITY=0 $BUNDLE install

    export RUBYOPT=-rbundler/setup
  '';
}

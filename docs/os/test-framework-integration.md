# Using the vpsAdminOS test framework in other projects

The vpsAdminOS test framework can be reused without copying its sources:

- Nix code defines QEMU machines and turns test definitions under `tests/suite/`
  into flake outputs.
- The upstream Ruby runner (`vpsadminos#test-runner`) evaluates your project's
  flake outputs, boots the machines and runs Ruby `testScript`s against them.

The important bit: the runner always evaluates/builds tests from the *current
working directory* using these flake outputs:

- `.#testsMeta.<system>` (discovery: `ls`, tags/labels, templates, ...)
- `.#tests.<system>."<test-path>"` (build JSON config for a test)

So to integrate the runner into another repository, your project needs:

1. A Nix flake that exports `tests` and `testsMeta`.
2. A `tests/` tree with `all-tests.nix` + `suite/` (and usually `make-test.nix`).

For writing tests (machine definition, `testScript`, tags, multiple scripts),
see [Testing](testing.md).

## Integration example (vpsAdmin)
The [vpsAdmin repository](https://github.com/vpsfreecz/vpsadmin) reuses the
framework directly via a flake input. The sections below describe the same
setup in a copy/paste-friendly way.

## Step-by-step integration (recommended, flake-based)

### 1) Add vpsAdminOS as a flake input
In your `flake.nix`, add vpsAdminOS and (recommended) align nixpkgs with it:

```nix
{
  inputs = {
    vpsadminos.url = "github:vpsfreecz/vpsadminos/<ref>";
    nixpkgs.follows = "vpsadminos/nixpkgs";
  };

  outputs = { self, nixpkgs, vpsadminos, ... }:
  let
    systems = [ "x86_64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in
  {
    # filled in below
  };
}
```

Tip for local development: point the input at a local checkout:
`vpsadminos.url = "path:../vpsadminos";`.

### 2) Add the `tests/` tree
Create this minimal layout in your project:

```text
tests/
  all-tests.nix
  make-test.nix
  suite/
    hello/
      boot.nix
```

`tests/make-test.nix` should delegate to the upstream helper (this is what
each suite file imports):

```nix
testFn:
{ vpsadminosPath, ... }@args:
let
  upstream = import (vpsadminosPath + "/tests/make-test.nix") testFn;

  # Optional: pass extra args to NixOS/vpsAdminOS modules as `specialArgs`.
  # The vpsAdmin repo uses this to make the vpsAdminOS checkout available as
  # `vpsadminos` inside NixOS module evaluation.
  mergedExtraArgs = { vpsadminos = vpsadminosPath; } // (args.extraArgs or { });
in
upstream (args // { extraArgs = mergedExtraArgs; })
```

`tests/all-tests.nix` lists tests (and templates) and is evaluated by the flake
helpers:

```nix
{
  pkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
  suiteArgs ? { },
}:
let
  vpsadminosPath = suiteArgs.vpsadminosPath or (throw "suiteArgs.vpsadminosPath is required");

  nixpkgs = import pkgs { inherit system; };
  lib = nixpkgs.lib;

  testLib = import (vpsadminosPath + "/test-runner/nix/lib.nix") {
    inherit pkgs system lib suiteArgs;
    suitePath = ./suite;
  };
in
testLib.makeTests [
  "hello/boot"
]
```

And a minimal suite test, `tests/suite/hello/boot.nix`:

```nix
import ../../make-test.nix ({ ... }: {
  name = "hello-boot";
  description = "Boot a VM and run a simple command";

  machine = {
    spin = "nixos";
    config = {
      networking.hostName = "hello";
      virtualisation.memorySize = 1024;
      virtualisation.cores = 2;
    };
  };

  testScript = ''
    machine.start
    machine.wait_for_boot
    machine.wait_for_service("test-shell")
    machine.succeeds("echo hello")
  '';
})
```

Note: test paths in `all-tests.nix` map to files under `tests/suite/` without
the `.nix` suffix, e.g. `hello/boot` -> `tests/suite/hello/boot.nix`.

### 3) Export flake outputs
Your flake must export `tests` and `testsMeta` so the runner can list and build
tests via `nix eval`/`nix build`:

```nix
{
  outputs = { self, nixpkgs, vpsadminos, ... }:
  let
    systems = [ "x86_64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in
  {
    tests = forAllSystems (system:
      vpsadminos.lib.testFramework.mkTests {
        inherit system;
        testsRoot = ./tests;
        suiteArgs = { vpsadminosPath = vpsadminos.outPath; };
      });

    testsMeta = forAllSystems (system:
      vpsadminos.lib.testFramework.mkTestsMeta {
        inherit system;
        testsRoot = ./tests;
        suiteArgs = { vpsadminosPath = vpsadminos.outPath; };
      });
  };
}
```

If your project uses a different nixpkgs than vpsAdminOS, also pass
`pkgsPath = nixpkgs.outPath;` to both `mkTests` and `mkTestsMeta`.

### 4) Expose the runner and add a wrapper script
Expose the upstream runner as an app:

```nix
{
  outputs = { self, nixpkgs, vpsadminos, ... }:
  let
    systems = [ "x86_64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in
  {
    apps = forAllSystems (system: {
      test-runner = {
        type = "app";
        program = "${vpsadminos.packages.${system}.test-runner}/bin/test-runner";
      };
    });

    # Optional convenience
    packages = forAllSystems (system: {
      test-runner = vpsadminos.packages.${system}.test-runner;
    });
  };
}
```

Then add a small wrapper script in your repo root, e.g. `test-runner.sh` (so
`$PWD` is correct):

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname "$0")" && pwd)"
cd "$ROOT"

exec nix run .#test-runner -- "$@"
```

Make it executable:

```bash
chmod +x test-runner.sh
```

The runner loads `tests/runner/extensions/*.rb` (if present) relative to the
current directory and writes JSON configs under `result/tests/`, so it is
important to run it from the flake root.

### 5) Run the suite
Invoke the wrapper with the usual runner commands:

- `./test-runner.sh ls` to list available tests.
- `./test-runner.sh test hello/boot` to run a single test.
- `./test-runner.sh test 'hello/*'` to run selected tests.
- `./test-runner.sh debug hello/boot` to open the interactive REPL.

### 6) Extend the runner when needed (optional)
Custom helpers can be added under `tests/runner/extensions/`. vpsAdmin adds
`tests/runner/extensions/vpsadmin_services.rb`, which:
- wraps `vpsadminctl` to make JSON-friendly `succeeds`/`fails` helpers;
- registers a custom machine class for machines tagged `vpsadmin-services`:
  ```ruby
  TestRunner::Hook.subscribe(:machine_class_for) do |machine_config|
    next unless machine_config.tags.include?('vpsadmin-services')

    VpsadminServicesMachine
  end
  ```
Use the same hook points to add helpers for your own services or machine types.
Two more hooks are available for post-run diagnostics:
- `:after_test_run` receives the test, scripts, machines and a `TestRunner::TestResult`.
- `:after_test_script_run` receives the test, machines and a `TestRunner::TestScriptResult`.
Example: gather logs only when a script ends with an unexpected result:
```ruby
TestRunner::Hook.subscribe(:after_test_script_run) do |script_result:, machines:, **|
  next if script_result.expected_result?

  machines.each_value do |machine|
    next unless machine.can_execute?

    machine.execute("journalctl -n 200 --unit #{script_result.test_script.name}")
  end
end
```

## Common gotchas
- `nix eval testsMeta failed`: the runner must be executed from the directory
  that contains your `flake.nix` and exports `testsMeta`.
- `suiteArgs.vpsadminosPath is required`: ensure `suiteArgs = { vpsadminosPath =
  vpsadminos.outPath; };` is passed in both `mkTests` and `mkTestsMeta`.
- If your repository uses `result` as a symlink (e.g. from `nix build`), change
  that. The runner writes to `result/tests/...` and will fail if `result`
  points into the Nix store.

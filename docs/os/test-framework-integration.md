# Using the vpsAdminOS test framework in other projects

The vpsAdminOS test framework can be reused without copying its sources. It
builds a Ruby test runner from `os/packages/test-runner/entry.nix`, boots QEMU
machines defined in Nix and runs Ruby test scripts against them. Tests are
discovered from `tests/all-tests.nix`, where each entry points to a Nix file
under `tests/suite/`.

## Integration example (vpsAdmin)
The [vpsAdmin repository](https://github.com/vpsfreecz/vpsadmin) reuses the
framework directly. The same pattern can be followed by other projects:

### Provide access to vpsAdminOS
- Keep a vpsAdminOS checkout next to your project or set `VPSADMINOS_PATH` to
  its location.
- Extend `NIX_PATH` with `vpsadminos=<path>` so imports such as
  `<vpsadminos/tests/make-test.nix>` work.

### Wrap the runner
Add a small wrapper that builds and runs the upstream runner with the current
repository as the working directory, e.g. `test-runner.sh` from vpsAdmin:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname "$0")" && pwd)"
OS_ROOT="${VPSADMINOS_PATH:-${ROOT}/../vpsadminos}"

export NIX_PATH="vpsadminos=${OS_ROOT}${NIX_PATH:+:${NIX_PATH}}"

mkdir -p "$ROOT/result"
nix-build --out-link "$ROOT/result/test-runner" "$OS_ROOT/os/packages/test-runner/entry.nix" >/dev/null
exec "$ROOT/result/test-runner/bin/test-runner" "$@"
```

### Mirror the test layout
- `tests/make-test.nix` can simply re-export the upstream helper:
  ```
  import <vpsadminos/tests/make-test.nix>
  ```
- `tests/all-tests.nix` uses the upstream library to enumerate tests:
  ```nix
  { pkgs ? <nixpkgs>, system ? builtins.currentSystem }:
  let
    nixpkgs = import pkgs { };
    lib = nixpkgs.lib;
    testLib = import <vpsadminos/test-runner/nix/lib.nix> {
      inherit pkgs system lib;
      suitePath = ./suite;
    };
  in
  testLib.makeTests [
    "vpsadmin/services-up"
  ]
  ```
- Place your Nix test definitions in `tests/suite/`, importing modules from
  vpsAdminOS as needed (e.g. `<vpsadminos/tests/configs/vpsadminos/base.nix>`)
  and adding project-specific configs.

### Extend the runner when needed
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

### Run the suite
Invoke the wrapper with the usual runner commands:

- `./test-runner.sh ls` to list available tests.
- `./test-runner.sh test 'pattern/*'` to run selected tests.
- `./test-runner.sh debug <test>` to open the interactive REPL.

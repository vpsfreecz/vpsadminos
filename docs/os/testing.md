# Testing

vpsAdminOS has a framework for writing and running tests. It is similar to tests
on [NixOS](https://nixos.org/nixos/manual/index.html#sec-nixos-tests), but it is
a different implementation.

Tests are run on one or more virtual machines running vpsAdminOS. These machines
are managed by the test framework. All tests can be found in the
[vpsAdminOS repository](https://github.com/vpsfreecz/vpsadminos/tree/staging/tests).

## Writing a test
Each test is a Nix file stored in directory `tests/suite`. A test has a name,
one or more virtual machines to run on and a Ruby script that is run from
the host system and which can interact with the virtual machines.

```nix
import ../make-test.nix (pkgs: {
  name = "my-test";

  description = ''
    It's a great test indeed
  '';

  machine = import ../machines/empty.nix pkgs;

  testScript = ''
    machine.start
    machine.succeeds("shell command that must succeed...")
  '';
})
```

Different machines may be needed for various storage, configuration or clustering
tests. If only one machine is needed, it is simply called `machine` and declared
as such. More machines can be defined as:

```nix
import ../make-test.nix (pkgs: {
  name = "my-test";

  description = ''
    It's a great test indeed
  '';

  machines = {
    first = import ../machines/empty.nix pkgs;
    second = import ../machines/empty.nix pkgs;
  };

  testScript = ''
    first.start
    second.start
  '';
})
```

Disks can be added as:

```nix
import ../make-test.nix (pkgs: {
  name = "my-test";

  description = ''
    It's a great test indeed
  '';

  machine = {
    # List of disk devices
    disks = [
      # 10 GB file sda.img will be created in the test's state directory
      # and added to the virtual machine
      { type = "file"; device = "sda.img"; size = "10G"; }
    ];

    # Machine configuration
    config = {
      imports = [ ../configs/base.nix ];

      boot.zfs.pools.tank = {
        layout = [
          { devices = [ "sda" ]; }
        ];
        doCreate = true;
        install = true;
      };
    };
  };

  testScript = ''
    machine.start
    machine.wait_for_zpool("tank")
  '';
})
```

See template machine configs in `tests/machines/`. vpsAdminOS configurations
used by machines for testing can be found in `tests/configs` and the tests
themselves in `tests/suite/`.

All tests have to be registered in `tests/all-tests.nix`, otherwise they cannot
be run.

## Running tests
To run the entire test suite, use:

```
./test-runner.sh test
```

Selected tests can be pattern-matched, e.g.:

```
./test-runner.sh test 'docker/*'
```

While developing a test, it is possible to start it with an interactive Ruby REPL:

```
./test-runner.sh debug my-test
```

The REPL can be used to issue the same commands as in the test script. The test
script itself can be run by calling method `test_script`. You can call method
`breakpoint` from inside the test to open the REPL from any point of execution.

## Expected failure
A test can be expected to fail. The failure is shown, but it does not result
in error exit status. If a test succeeds and we expected it to fail, it is
considered as an error.

```nix
import ../make-test.nix (pkgs: {
  name = "my-failed-test";

  description = ''
    It's a great test indeed
  '';

  expectFailure = true;

  machine = import ../machines/empty.nix pkgs;

  testScript = ''
    machine.start
    machine.succeeds("shell command that fails...")
  '';
})
```

## Temporary config changes
It is possible to change all test machine configurations by creating
`os/configs/tests.nix` file, e.g. to change a kernel version used in tests:

```nix
{ config, ... }:
{
  boot.kernelVersion = "6.1.30";
}
```

# Testing

vpsAdminOS has a framework for writing and running tests. It is similar to tests
on [NixOS](https://nixos.org/nixos/manual/index.html#sec-nixos-tests), but it is
a different implementation.

Tests are run on one or more virtual machines running vpsAdminOS. These machines
are managed by the test framework. All tests can be found in the
[vpsAdminOS repository](https://github.com/vpsfreecz/vpsadminos/tree/master/tests).

## Writing a test
Each test is a Nix file stored in directory `tests/suite`. A test has a name,
one or more virtual machines to run on and a Ruby script that is run from
the host system and which can interact with the virtual machines.

```nix
import ../make-test.nix (pkgs: {
  name = "my-test";

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

## Running a test

```
make test TEST=<name>
```

The test runner will print path to a temporary directory where the test's log
files and state is kept:

 - `<machine>-console.log` output from the virtual machine console
 - `<machine>-log.log` all executed commands and their results

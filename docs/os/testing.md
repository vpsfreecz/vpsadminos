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
import ../make-test.nix ({ pkgs }: {
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
import ../make-test.nix ({ pkgs }: {
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
import ../make-test.nix ({ pkgs }: {
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

### Machine spins (vpsAdminOS vs NixOS)
Machines default to vpsAdminOS. To boot NixOS instead, set `spin = "nixos"` on
the machine definition and provide the NixOS config you want to test. You can
mix vpsAdminOS and NixOS machines within a single test.

Minimal NixOS example:

```nix
import ../make-test.nix ({ pkgs }: {
  name = "nixos-example";
  description = "NixOS machine example";

  machine = {
    spin = "nixos";
    config = {
      networking.hostName = "nixos";
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
    };
    # optional extra modules
    # modules = [ ./extra-module.nix ];
  };

  testScript = ''
    machine.start
    machine.wait_for_boot
    machine.wait_for_service("test-shell")
    machine.succeeds("echo hello")
  '';
})
```

## Running tests
To run the entire test suite, use:

```
./test-runner.sh test
```

Selected tests can be pattern-matched, e.g.:

```
./test-runner.sh test 'docker/*'
```

Tests can also be selected by tags, labels and metadata expressions. Tags are
listed in the test definition using `tags = [ ... ];`; labels are listed using
`labels = { ... };`. Test scripts inherit test-level tags and labels, and can
add or override their own metadata.

Existing tag and label filters are simple AND filters:

```
./test-runner.sh test -t ci
./test-runner.sh test -t ci -t docker
./test-runner.sh test -t ^manual
./test-runner.sh test -l runtime=long
./test-runner.sh test -l runtime!=long
```

For more advanced selection, use `--filter` with a metadata expression. The
virtual label `tag` matches tags; other names match labels. Expressions use
`&&` for AND, `||` for OR and parentheses for grouping:

```
./test-runner.sh ls --filter 'tag=ci && tag!=manual'
./test-runner.sh ls --filter 'tag=ci && runtime!=long'
./test-runner.sh test -t ci --filter 'tag=vps || tag=storage'
./test-runner.sh test --filter 'tag=ci && (tag=docker || tag=podman)'
./test-runner.sh test -t ci --filter 'runtime!=long && (tag=docker || tag=podman)'
```

Shell quoting is required for expressions containing `&&`, `||` or parentheses.

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
import ../make-test.nix ({ pkgs }: {
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

## Multiple test scripts
Each test can contain multiple test scripts. Test scripts are a part of
test name and be run selectively.

```nix
import ../make-test.nix ({ pkgs }: {
  name = "my-test";

  description = ''
    It's a great test indeed
  '';

  expectFailure = true;

  machine = import ../machines/empty.nix pkgs;

  testScripts = {
    script1 = {
      # Each script be expected to fail
      # expectFailure = false;

      # The test itself
      script = ''
        machine.start
        machine.succeeds("uptime")
      '';
    };

    script2 = {
      script = ''
        machine.succeeds("ps aux")
      '';
    };
  };
})
```

`./test-runner.sh ls 'my-test#*'` would show these tests as:

```
my-test#script1
my-test#script2
```

Script name is separated from test name by a hash (`#`). Test scripts of
one test are run in the same environment and share the same virtual machines.
By default, they run one after the other in random order.

Tests can opt into parallel test script execution with `testScriptJobs`:

```nix
{
  testScriptJobs = 2;

  testScripts = {
    script1.script = ''
      machine.succeeds("uptime")
    '';

    script2.script = ''
      machine.succeeds("ps aux")
    '';
  };
}
```

Parallel scripts share the same VM state, so they must avoid conflicting
changes to the machine. Each running script gets its own test shell.

Machines can declare named extra shells for commands that should be able to
run without blocking the script's default shell:

```nix
{
  machine = {
    shells = [ "first" "second" ];
  };

  testScript = ''
    machine.shells['first'].succeeds("sleep 10")
    machine.succeeds("uptime", shell: "second")
  '';
}
```

Named shells share the same VM state as the default shell. Shell names can be
looked up as strings or symbols, e.g. `machine.shells[:first]`.

## Test templates
Templates can be used to create multiple instances of a test. The difference between
templates and multiple test scripts is that tests created by templates are isolated,
have their own virtual machines and can run in parallel.

```nix
import ../make-template.nix ({ distribution, version }: rec {
  instance = "${distribution}-${version}";

  test = { pkgs }: {
    name = "my-template@${instance}";

    description = ''
      Test something on ${distribution}-${version}
    '';

    machine = import ../machines/tank.nix pkgs;

    testScript = ''
      machine.wait_for_osctl_pool("tank")
      machine.wait_until_online
      machine.succeeds("osctl ct new --distribution ${distribution} --version ${version} testct")
    '';
  };
})
```

Within `all-tests.nix`, the template would be listed as:

```nix
{ template = "my-template"; instances = distributions.all; }
```

`./test-runner.sh ls 'my-template@*'` would show these tests as:

```
my-template@debian-stable
my-template@ubuntu-24.04
...
```

## RSpec expectations
Test scripts can use RSpec expectations and optionally also example groups similar
to RSpec. We reuse [rspec-expectations](https://rspec.info/features/3-13/rspec-expectations/)
and provide our own implementation of [rspec-core](https://rspec.info/features/3-13/rspec-core/).
We aim to be compatible with RSpec when possible.

The following test demostrates available RSpec features.

```nix
import ../make-test.nix ({ pkgs }: {
  name = "my-test";

  description = ''
    Test with RSpec expectations
  '';

  machine = import ../machines/tank.nix pkgs;

  testScript = ''
    # Optional global configuration for example groups / examples
    configure_examples do |config|
      # `:defined`, `:rand`, instance of `Random` or `Integer` used as a seed
      # Defaults to `:rand` if not set
      config.default_order = :defined
    end

    before(:suite) do
      puts 'block executed before all examples'
    end

    # Create an example group
    describe 'machine' do
      before(:context) do
        puts 'block executed before examples in this group'
      end

      after(:context) do
        puts 'block executed after examples in this group'
      end

      before(:example) do
        puts 'block executed before each example'
      end

      after(:example) do
        puts 'block executed after each example'
      end

      it 'can execute commands' do
        _, output = machine.succeeds('echo hello')
        expect(output.strip).to eq('hello')
      end

      example 'without a block is skipped'

      skip 'examples created by skip are also skipped' do
        puts 'this will not run'
      end

      example 'can be skipped from the code block' do
        skip
        skip('with a reason')
      end

      pending 'examples are expected to fail' do
        # This example will fail if expectations will be met
        expect(0).to eq(1)
      end

      example 'can be marked as pending from the code block' do
        pending
        pending('this is expected to fail')
        expect(0).to eq(1)
      end

      context 'nested example group with custom order of evaluation', order: :rand do
        example '#1'
        example '#2'
      end
    end

    after(:suite) do
      puts 'block executed after all examples'
    end
  '';
})
```

Groups and examples are evaluated in random order unless configured otherwise.

## Temporary config changes
It is possible to change all test machine configurations by creating
`os/configs/tests.nix` file, e.g. to change a kernel version used in tests:

```nix
{ config, ... }:
{
  boot.kernelVersion = "6.1.30";
}
```

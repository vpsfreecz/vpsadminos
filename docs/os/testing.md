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

## Disk lifecycle

Managed file-backed disks preserve their contents on VM startup by default.
This includes NixOS root disks. A stop/start within a test reuses those disks;
set `preserve = false` on a disk to recreate it on each start.

vpsAdminOS VMs booted from squashfs still have a temporary root filesystem.
Files in that root disappear on reboot, while data on attached disks, including
ZFS pools and containers, remains. Firmware-booted installations keep their
installed root on the attached disk.

| Command | Initial reset | Cleanup on exit |
| --- | --- | --- |
| `test` | None | Delete managed disks |
| `test --fresh` | All managed disks, once per attempt | Delete managed disks |
| `test --no-destructive` | None | Keep disks |
| `test --no-destructive --fresh` | All managed disks, once per attempt | Keep disks |
| `debug` | None | Keep disks |
| `debug --fresh` | All managed disks, before the REPL opens | Keep disks |

The initial reset from `-f, --fresh` applies regardless of `preserve`. It does
not reset disks again between examples or VM restarts. A disk with
`preserve = false` is recreated when the VM starts, even in debug mode.
`machine.destroy_disks` explicitly removes managed disks regardless of their
preservation setting. Block devices and files with `create = false` are
externally managed and are never created, replaced, or deleted by these actions.
They cannot use `preserve = false`.

Test and debug use the same state directory for a given test path and
`--state-dir`. For example, retain a failed run and inspect it with:

```sh
./test-runner.sh test --no-destructive --fresh driver/nixos
./test-runner.sh debug driver/nixos
```

Each test has a lock held through VM cleanup and result publication. A second
command targeting the same state fails while that lock is held. Scripts of the
same test share its state. Use separate `--state-dir` values for independent
runs, including tests from different repositories.

Retaining a disk does not resize it or copy a newer source image into it.
NixOS direct boot requires the selected system closure to exist on its root
filesystem. After changing a test's NixOS configuration, use `--fresh` to start
from its new image, or copy and activate the closure in the running VM before
restarting it.

A managed disk can use `image = /path/to/source.img` instead of `size`. OSVM
copies the image when creating the disk. Preparation uses a temporary file next
to the destination; a failed copy or resize leaves the previous disk intact.

For a NixOS machine, `rootDisk` overrides the generated root disk descriptor:

```nix
machine = {
  spin = "nixos";
  rootDisk.preserve = false;
  config.system.stateVersion = "26.05";
};
```

The generated root uses `{machine}-root.img` and is attached before additional
disks. Root and additional disks use the same `device`, `type`, `create`,
`preserve`, `image`, and `size` fields. JSON configurations using `diskImage`
remain readable; they cannot also specify `rootDisk`.

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
      # This scratch disk is blank on every VM start
      { type = "file"; device = "scratch.img"; size = "1G"; preserve = false; }
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

## Livepatch Intel CI distribution

The existing `livepatch-intel` selector includes cumulative .95 NFS cancellation.
Native .110 NFS cancellation belongs to the existing
`livepatch-qualification-intel-representative-v6` selector, after that row's v6
qualification. Both rows use `intel-kvm` and execute their scripts serially.
This avoids placing both long NFS groups in one 350-minute step. The ordinary
`ci` selector still includes both groups; their machines, examples, 25 forced
stop/restart cycles and per-example deadlines are unchanged. No matrix row or
longer step deadline is added.

## Livepatch qualification shutdown diagnostics

Livepatch qualification guests retain a shutdown-only RSS diagnostic.
After workload cleanup, a return probe mirrors `__mmdrop` completion during
poweroff to the kernel console, with the return caller, task name and
online/dying CPU masks. Console tracing is allocated at boot but remains off
through the workload. Console verbosity is raised only after cleanup so the
records reach the serial console rather than only the dmesg ring. They help
investigate late accounting BUGs; they do not suppress faults or establish
that a particular BUG is harmless.
The counter-sum helper itself is not traceable on the pinned boot kernel;
the diagnostic respects that restriction and observes mm teardown instead.

If qualification already failed, its after-example hook reports unavailable
diagnostics or cleanup without replacing the original example failure. A
wedged cgroup migration can also prevent the guest from forking the commands
needed to collect diagnostics. No successful cleanup or snapshot is inferred
from this fallback. Cleanup exceptions after completed qualification still
propagate and fail the test.

## Guest kernel failures

Unexpected guest kernel failures remain fatal and are not retried. During
cleanup, the runner continues collecting the console so that a panic's later
stack traces and per-CPU tracing dumps can reach `<machine>-console.log`.
Collection stops at console EOF, after 30 seconds without new console bytes,
or 600 seconds after the first failure was detected, whichever comes first.
The runner then terminates the guest. New output, including repeated failure
messages, cannot extend that hard collection deadline.

This wait only affects failure cleanup: it does not suppress kernel-failure
detection, permit further guest commands, or turn a failing test into a pass.
A dump can still be incomplete if a collection limit is reached.

## NFS cancellation lock diagnostics

The NFS cancellation test's remote-lock example enables a dedicated trace
instance while the FIFO-held lock and competing client are exercised. Its
`nfs4`, `nfsd`, `sunrpc`, and `filelock` event rings are bounded to 1 MiB per
virtual CPU. On failure, tracing is stopped and per-CPU loss statistics and
the retained events are collected before the holder is released, alongside
lock, mount, process, firewall and server-state snapshots. A wrapped ring is
not a complete operation history; use the recorded loss statistics.

The trace instance and enabled events are removed after the example. Capture
and cleanup do not turn a failed lock assertion into a pass. Server diagnostics
enter the server's mount, network and PID namespaces so its private proc mount
can resolve the diagnostic process's network statistics.

Failure snapshots also retain each live `flock` process's descriptors and
`fdinfo`, plus device/inode/link-count observations for those descriptors and
the server/client lock paths. This distinguishes a live lock holder from a
stale or different path without changing the remote contention assertion.
These are post-failure observations: the short-lived contender has already
closed its descriptor, and path metadata can require fresh NFS requests.
Use the retained trace and its loss statistics to establish operation-time
filehandle identity; a matching pathname alone is not proof.

A separate transport ring starts before each protocol's first client mounts.
It records `inet_sock_set_state`, `tcp_send_reset`, and `tcp_receive_reset`,
with 1 MiB per virtual CPU. State changes and received resets are filtered
to source or destination port 2049. Sent resets have packed socket addresses
rather than scalar port fields, so they are retained without a port filter. A
callback connection can predate the lock example, so this history is not
cleared when the operation-time NFS trace starts. Lock failure collects both
rings and their loss statistics, plus server/client TCP socket snapshots.
The transport instance is removed after the protocol group. Socket snapshots
are post-failure observations, and an overwritten ring cannot establish that
an earlier disconnect or reset was absent. No lock or cancellation assertion
depends on a particular transport topology or on the diagnostic contents.

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

Generated direct-boot test guests use flow-controlled `virtserialport` devices
for command traffic, separate from the serial console used for boot and kernel
diagnostics. Unlike `virtconsole`, these ports do not discard shell replies
when the host socket is temporarily full. Each guest service opens its named
`/dev/virtio-ports/org.osvm.shellN` device once and shares that descriptor for
stdin, stdout and stderr; it is not a TTY and does not use `stty`.

The machine JSON records `testShellTransport`, which can be `virtserialport`
or `virtconsole`. Old JSON without this field keeps the legacy `/dev/hvcN`
transport. Firmware-boot machines also default to `virtconsole`, because their
guest image is supplied separately. A machine can explicitly set
`testShellTransport` when its image needs a different transport; the guest
service and host port must agree. For separately built vpsAdminOS images, the
matching guest option is `osctl.test-shell.transport`.

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

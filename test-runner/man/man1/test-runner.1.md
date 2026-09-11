# test-runner 1                   2026-06-03                               26.05

## NAME
`test-runner` - vpsAdminOS test suite evaluator

## SYNOPSIS
`test-runner` [*global options*] *command* [*command options*] [*arguments...*]

## DESCRIPTION
`test-runner` is a command-line tool to evaluate vpsAdminOS test suite, running
selected tests and reporting results.

## COMMANDS
`ls` [*path-pattern*]
  List available tests, filtered by *path-pattern* if provided.

    `-l`, `--label` *label*`=`*value* | *label*`!=`*value*
      Filter tests by selected label, which is either tested for
      equality or inequality.

    `-t`, `--tag` *tag*|`^`*tag*
      Filter tests that have *tag* set. If the tag begins with `^`, then
      filter tests that do not have *tag* set.

    `--filter` *expr*
      Filter tests by metadata expression. Expressions can test tags and labels,
      combine conditions with `&&` and `||`, and group them with parentheses.
      Use `tag=`*value* to require a tag and `tag!=`*value* to reject a tag.
      Other keys are treated as labels, e.g. `runtime!=long`.

    `--system` *system*
      Nix system to evaluate tests for. Defaults to `x86_64-linux`.

    `--test-config` *path*
      Path to a Nix file returning additional test framework configuration.
      Requires the tested flake to export
      `lib.testFramework.mkTests` and `lib.testFramework.mkTestsMeta`.

`test` [*path-pattern*]
  Run all or selected tests.

    `-l`, `--label` *label*`=`*value* | *label*`!=`*value*
      Filter tests by selected label, which is either tested for
      equality or inequality.

    `-t`, `--tag` *tag*|`^`*tag*
      Filter tests that have *tag* set. If the tag begins with `^`, then
      filter tests that do not have *tag* set.

    `--filter` *expr*
      Filter tests by metadata expression. Expressions can test tags and labels,
      combine conditions with `&&` and `||`, and group them with parentheses.
      Use `tag=`*value* to require a tag and `tag!=`*value* to reject a tag.
      Other keys are treated as labels, e.g. `runtime!=long`.

    `-j`, `--jobs` *n*|`auto`
      Maximum number of tests to run in parallel. When set to `auto`, the
      runner starts enough scheduler workers for all selected tests and lets
      resource reservations decide how many VMs can actually run.

    `--max-memory-mib` *n*
      Maximum memory available to running test VMs, in MiB. Detected memory
      capacity is limited by memory available when the run starts and cannot
      increase during the run. This value is an upper bound and is used as a
      fallback when detection is unavailable.

    `--max-shm-mib` *n*
      Maximum `/dev/shm` space available to running test VMs, in MiB. Detected
      capacity is limited by space available when the run starts and cannot
      increase during the run. This value is an upper bound and is used as a
      fallback when detection is unavailable.

    `--max-cpus` *n*
      Maximum CPUs available to running test VMs. Detected CPU capacity is
      refreshed during the run; this value is an upper bound and is used as a
      fallback when detection is unavailable.

    `--memory-overcommit` *factor*
      Multiply detected memory capacity by *factor* before applying the
      configured reserve and maximum. Defaults to `1.0`.

    `--shm-overcommit` *factor*
      Multiply detected `/dev/shm` capacity by *factor* before applying the
      configured reserve and maximum. Defaults to `1.0`.

    `--cpu-overcommit` *factor*
      Multiply detected CPU capacity by *factor* before applying the configured
      reserve and maximum. Defaults to `1.5`.

    `--resource-refresh-interval` *seconds*
      How often to refresh detected resource capacity while scheduling tests.
      Memory and `/dev/shm` limits can only decrease during a run; CPU capacity
      can increase or decrease. Defaults to `15`.

    `--status-interval` *seconds*
      How often to print suite status while tests are running. The status
      includes the aggregate passing or failed state, expected successes,
      expected failures, unexpected failures, unexpected successes, running
      tests, and remaining tests. Failed status messages also list the test
      scripts with unexpected results. Defaults to `300`. Set to `0` to
      disable periodic suite status messages.

    `-v`, `--verbose`
      Show verbose diagnostic progress messages, including the per-test
      heartbeat with the test log path and last test output.

    `--memory-reserve-mib` *n*
      Memory to keep reserved from detected or configured capacity, in MiB.
      Defaults to `8192`.

    `--shm-reserve-mib` *n*
      `/dev/shm` space to keep reserved from detected or configured capacity,
      in MiB. Defaults to `8192`.

    `--cpu-reserve` *n*
      CPUs to keep reserved from detected or configured capacity.

    `-f`, `--fresh`
      Reset all managed disk files before each test attempt, regardless of
      their preservation settings. VM restarts within the attempt follow each
      disk's `preserve` setting.

    `--system` *system*
      Nix system to evaluate tests for. Defaults to `x86_64-linux`.

    `--test-config` *path*
      Path to a Nix file returning additional test framework configuration.
      Requires the tested flake to export
      `lib.testFramework.mkTests` and `lib.testFramework.mkTestsMeta`.

    `--timeout` *n*
      Default timeout for machine commands that wait until execution becomes
      possible, or until a command fails or succeeds. This option changes
      the default value, which is used when tests do not set the timeout
      themselves. In seconds, defaults to `900`.

    `--stop-on-failure`
      Stop scheduling new tests after an unexpected failure or unexpected
      success exhausts its configured script attempts. Guest kernel failures
      stop scheduling immediately and are never retried. Tests that are
      already running finish normally so their logs and results are retained.
      Disabled by default.

    `--destructive`, `--no-destructive`
      Delete managed disks on exit, including after a test failure. Enabled by
      default. Use `--no-destructive` to retain disks for another run or debug.
      This cleanup applies regardless of each disk's `preserve` setting.

    `--state-dir` *dir*
      Set custom path to directory where generated configs, logs, and test
      state are stored.
      Defaults to `$TMPDIR` or `/tmp`.

    `--system` *system*
      Nix system to evaluate tests for. Defaults to `x86_64-linux`.

    `--test-config` *path*
      Path to a Nix file returning additional test framework configuration.

## FILTER EXPRESSIONS
`--filter` accepts boolean expressions over test script metadata:

- `tag=ci` matches scripts tagged `ci`.
- `tag!=manual` matches scripts without tag `manual`.
- `runtime=long` matches scripts with label `runtime` set to `long`.
- `runtime!=long` matches scripts whose `runtime` label is not `long`.

Use `&&` for AND, `||` for OR and parentheses for grouping. `&&` binds more
strongly than `||`. Multiple `--filter`, `--tag` and `--label` options are
combined with AND.

Examples:

```
test-runner ls --filter 'tag=ci && tag!=manual'
test-runner test --filter 'tag=ci && (tag=vps || tag=storage)'
test-runner test -t ci --filter 'runtime!=long && (tag=vps || tag=storage)'
./test-runner.sh test -t ci --filter 'tag=vps || tag=storage'
./test-runner.sh ls --filter 'tag=ci && runtime!=long'
```

Shell quoting is required for expressions containing `&&`, `||` or parentheses.

`debug` *test*
  Run test interactively. The test script is not run, instead Ruby REPL is opened.
  The REPL can be used to issue commands as from the test script. The test is
  run in a non-destructive mode: managed disks are kept on exit. Test and debug
  use the same state for the same test path and `--state-dir`, so debug can
  inspect disks retained by `test --no-destructive`. A concurrent command using
  that state is refused.

    `-f`, `--fresh`
      Reset all managed disks before opening the REPL. Subsequent VM starts
      follow each disk's `preserve` setting.

    `--state-dir` *dir*
      Set custom path to directory where generated configs, logs, and test
      state are stored.
      Defaults to `$TMPDIR` or `/tmp`.

## DISKS

Managed file-backed disks, including NixOS roots, default to `preserve = true`:
they are created when missing and reused on VM startup. `preserve = false`
recreates an individual disk on every start, including in debug mode. `--fresh`
resets all managed disks once before execution; `--destructive` controls their
deletion afterward. Neither action modifies external files (`create = false`)
or block devices.

vpsAdminOS squashfs boots retain attached disks but recreate their temporary
root filesystem. Installed systems booted from disks retain those disks.
Retained NixOS roots need the selected system closure before direct boot; after
changing configuration, use `--fresh` or update the running VM before restart.

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`test-runner` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).

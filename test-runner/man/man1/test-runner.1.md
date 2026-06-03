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

    `-j`, `--jobs`
      Number of tests to run in parallel.

    `-f`, `--fresh`
      Recreate disk files for virtual machines if they already exist.

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
      Stop further execution when a test fails.

    `--destructive`
      Determines whether machine disk files are kept

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
  run in a non-destructive mode, i.e. machine disks remain intact between test
  runs.

    `--state-dir` *dir*
      Set custom path to directory where generated configs, logs, and test
      state are stored.
      Defaults to `$TMPDIR` or `/tmp`.

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`test-runner` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).

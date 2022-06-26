# test-runner 1                   2022-06-26                             22.05

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

`test` [*path-pattern*]
  Run all or selected tests.

    `-y`, `--yes`
      Do not ask for confirmation, assume yes.

    `-j`, `--jobs`
      Number of tests to run in parallel.

    `-t`, `--timeout` *n*
      Default timeout for machine commands that wait until execution becomes
      possible, or until a command fails or succeeds. This option changes
      the default value, which is used when tests do not set the timeout
      themselves. In seconds, defaults to `900`.

    `--stop-on-failure`
      Stop further execution when a test fails.

    `--destructive`
      Determines whether machine disk files are kept

    `--state-dir` *dir*
      Set custom path to directory where the test logs and state are stored.
      Defaults to `$TMPDIR` or `/tmp`.

`debug` *test*
  Run test interactively. The test script is not run, instead Ruby REPL is opened.
  The REPL can be used to issue commands as from the test script. The test is
  run in a non-destructive mode, i.e. machine disks remain intact between test
  runs.

    `--state-dir` *dir*
      Set custom path to directory where the test logs and state are stored.
      Defaults to `$TMPDIR` or `/tmp`.

## BUGS
Report bugs to https://github.com/vpsfreecz/vpsadminos/issues.

## ABOUT
`test-runner` is a part of [vpsAdminOS](https://github.com/vpsfreecz/vpsadminos).

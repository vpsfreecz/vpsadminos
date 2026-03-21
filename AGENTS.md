# Repository Guidelines

## Project Structure & Module Organization
- `os/`: NixOS-based system definitions, package overlays, and QEMU runner; gem packaging lives under `os/packages/*`.
- `osctl`, `osctld`, `libosctl`, `osctl-*`, `osup`, `svctl`, `osvm`, `test-runner`: Ruby gems/CLIs that back container management.
- `image-scripts/`: install media helpers; `tools/`: maintenance scripts (e.g., gem updates); `docs/`: MkDocs sources; `tests/`: Nix VM test suites plus machines/configs.

## Development Environment
- Enter via `nix develop` (flakes) or `nix-shell` to pull Ruby, Nix, mkdocs, and ccache; set `NIX_PATH` to the matching NixOS release noted in `README.md`.
- Keep ccache available for kernel builds; build/test commands create `result/` symlinks in the repo root.

## Build, Test, and Development Commands
- `make`: build the vpsAdminOS system derivation in `os/`.
- `make qemu`: boot the built system in QEMU with persistent `sda.img`/`sdb.img`.
- `make toplevel`: build the system closure without launching QEMU.
- `./test-runner.sh test`: run the full Nix VM test suite; add patterns (`./test-runner.sh test 'docker/*'`) to scope runs.
- `./test-runner.sh debug <name>`: interactive REPL for a single test; `./test-runner.sh ls '<pattern>'` lists discovered cases.
- `make doc` / `make doc_serve`: build or serve the MkDocs site.

## Coding Style & Naming Conventions
- `.editorconfig`: 2-space indent for Ruby/Nix/C/XML, tabs-size-4 for Go, LF endings, UTF-8.
- Ruby targets 3.4; run `bundle exec rubocop` where enabled; favor explicit predicates and concise methods (`Style/NumericPredicate` enforced).
- Format Nix with `nixfmt`/`nixpkgs-fmt`; keep attribute names snake_case and package derivations under `os/packages`.
- Tests/scripts: snake_case filenames; gem/module names match their directories (`osctl-oomd`, `libosctl`, etc.).

## Testing Guidelines
- Add tests in `tests/suite/*.nix` and register them in `tests/all-tests.nix`; reuse machines from `tests/machines/*.nix` and configs from `tests/configs/`.
- Use `my-test#script` for multi-script cases; set `expectFailure = true` when capturing known failures.
- While developing, run `./test-runner.sh ls '<pattern>'` to explore cases and `./test-runner.sh debug <name>` for stepwise checks; per-test state lives under `result/`.

### Test runner tips
- When there are **no local changes** in `osvm` or `test-runner`, prefer the prebuilt gems: run from repo root with `./test-runner.sh …`.
- After modifying `osvm` or `test-runner`, run under nix-shell to pick up local code: `nix-shell test-runner/shell.nix --run 'bundle exec ./test-runner/bin/test-runner <args>'` (cwd must be repo root so `$PWD/tests` is found).

### Overcommit hooks
- Do not bypass overcommit hooks. Commits must be created with the pre-commit hooks enabled (nixfmt, RuboCop, etc.) or run `nix-shell --run 'overcommit --run'` from repository root to ensure they pass before committing.

## Commit & Pull Request Guidelines
- Follow existing history: `<area>: <change>` (e.g., `os: ...`, `tests/distributions: ...`); present tense, scoped subjects.
- Keep commits focused and update docs/man pages when behavior changes.
- PRs should describe problem and solution, list commands/tests executed, link related issues, and attach logs/screenshots for user-visible changes.
- Note any NIX_PATH/binary cache expectations reviewers need to reproduce builds.

## Image-Scripts Release Bumps
- Use the `update-redhat-family-image-releases` skill for Rocky, AlmaLinux, Fedora, or full Red Hat-family image release updates. The versioned skill lives in `skills/update-redhat-family-image-releases/` and covers upstream HTTP repo lookups, the exact `build.sh` edits, required `./test-runner.sh test image-scripts/test@<image-name>` verification, and commit split guidance.

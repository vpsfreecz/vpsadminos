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

## Commit & Pull Request Guidelines
- Follow existing history: `<area>: <change>` (e.g., `os: ...`, `tests/distributions: ...`); present tense, scoped subjects.
- Keep commits focused and update docs/man pages when behavior changes.
- PRs should describe problem and solution, list commands/tests executed, link related issues, and attach logs/screenshots for user-visible changes.
- Note any NIX_PATH/binary cache expectations reviewers need to reproduce builds.

## Image-Scripts Release Bump Checklist
- Always fetch exact release RPM versions from the HTTP repo directory listings (no guessing). Inspect the `Packages/*` listing for each distro.
- Rocky (9, 10, future): set `POINTVER` to the current minor (e.g. 9.7, 10.1) and point `RELEASE` to `rocky-release-${POINTVER}-<version>.rpm` under `BaseOS/.../Packages/r/`.
- AlmaLinux (9, 10, future): set `POINTVER` to the current minor (e.g. 9.7, 10.1) and point `RELEASE` to `almalinux-release-${POINTVER}-<version>.rpm` under `BaseOS/.../Packages/`.
- Fedora rawhide: set `RAWHIDE_RELVER` to the version found in `fedora-release*` RPMs in `Packages/f/`; the `RELEASE` URLs must use that same value.
- Make separate commits per distribution bump, e.g. `image-scripts: update rocky-9 to <ver>`, `image-scripts: update almalinux-9 to <ver>`, `image-scripts: update fedora-rawhide release to <ver>`.

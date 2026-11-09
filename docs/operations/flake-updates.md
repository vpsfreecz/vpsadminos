# Automated flake updates

The [`flake-update.yml`](https://github.com/vpsfreecz/vpsadminos/blob/staging/.github/workflows/flake-update.yml)
workflow updates all root inputs using an independently pinned confctl CI tool. It requires ancestry preservation across the changed
lock graph and stops publication on rejection or unavailable evidence. It
checks the final lock against a saved baseline after hooks and checks, then
uses an ordinary non-force push. If the target branch advances, rerun from its
new baseline instead of rebasing the old lock update. The CI tool does not
become a runtime flake input.

The workflow saves confctl's Git mirrors in `~/.cache/confctl` even when an
update is rejected. Every update checks ancestry, whether the cache was
restored or freshly cloned.

See the [shared guard contract](https://github.com/vpsfreecz/confctl/blob/822c0e35dbe2549111912f539116b4225dfd3035/docs/flake-inputs.md#guarded-automated-updates) for supported sources and failure behavior.

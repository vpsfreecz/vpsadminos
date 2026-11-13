---
name: manage-livepatch
description: Route vpsAdminOS numbered kernel livepatch work to the repository-owned release process, target page, source interfaces and stable maintainer commands. Use when creating, updating, qualifying, operating or retiring a vpsAdminOS kernel livepatch release.
---

# Manage a kernel livepatch

This skill is a router. It does not replace the repository process or a target
page's release-specific safety instructions.

1. Read the repository [agent instructions](../../AGENTS.md).
2. Read the [canonical livepatch process](../../docs/os/livepatches/process.md)
   and [downstream patch-series policy](../../docs/os/patch-series-policy.md).
3. Read the applicable page under `docs/os/livepatches/`. If no target page
   exists, start it from the [target-page template](../../docs/os/livepatches/template.md).
4. Inspect the [catalog/normalizer](../../os/livepatches/lib.nix),
   [target-bound producer](../../os/packages/livepatch-module/default.nix) and
   [runtime manager](../../os/modules/services/livepatches/default.nix) for the
   interfaces affected by the request.
5. Use the stable maintainer entry points below. Follow the canonical process
   for their prerequisites, evidence and stopping conditions.

```sh
tools/livepatch/discover.sh --plan livepatch-plan.json --matrix livepatch-matrix.json
tools/livepatch/capture.sh --plan livepatch-plan.json --output livepatch-capture.json --evidence-dir livepatch-evidence
tools/livepatch/verify.sh --plan livepatch-plan.json --capture livepatch-capture.json
tools/livepatch/verify.sh --plan livepatch-plan.json --capture livepatch-capture.json --row-id ID --result result.json
tools/livepatch/run-profile.sh --plan livepatch-plan.json --capture livepatch-capture.json --row-id ID --state-dir DIR
```

Generic test selectors are `kernel/livepatch-batch@<row-id>`,
`kernel/livepatch-set@<row-id>` and `kernel/livepatch-fix@<row-id>`.

Do not treat workflow job names, flake evaluation expressions, temporary
artifact paths, direct Nix store commands or internal JSON queries as public
interfaces.

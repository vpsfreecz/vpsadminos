#!/usr/bin/env bash
set -euo pipefail
umask 077

base=$(git rev-parse HEAD)
git switch --detach "$base"
pruner=(python3 -B tools/kernel-retention.py)
private=$(mktemp -d)
trap 'rm -rf -- "$private"' EXIT
mkdir "$RUNNER_TEMP/kernel-retention"
out="$RUNNER_TEMP/kernel-retention"

"${pruner[@]}" collect --output "$private/fleet.json"
as_of=$(date -u +%FT%T.%6NZ)
write=()
if [[ ${KERNEL_RETENTION_WRITE:-} == true ]]; then
  write=(--write)
  export GIT_AUTHOR_NAME='github-actions[bot]'
  export GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
fi
"${pruner[@]}" apply --base "$base" --fleet "$private/fleet.json" --as-of "$as_of" \
  --evidence "$out/evidence.json" "${write[@]}" | tee "$private/report.json"

if [[ ${#write[@]} == 0 ]] || jq -e '.eligible == []' "$private/report.json" >/dev/null; then
  exit 0
fi

# Verify each retirement commit before bundling the series.
candidate=$(git rev-parse HEAD)
"${pruner[@]}" verify --base "$base" --candidate "$candidate" --evidence "$out/evidence.json" > "$out/proof.json"
mkdocs build --strict --site-dir "$private/site"
jq '.base.qualification' "$out/evidence.json" > "$private/base-qualification.json"
bash tools/livepatch/discover.sh --input "$private/base-qualification.json" \
  --plan "$private/base-plan.json" --matrix "$private/base-matrix.json"
nix eval --offline --no-write-lock-file --option allow-import-from-derivation false \
  --json .#livepatchQualification.x86_64-linux > "$private/candidate-qualification.json"
bash tools/livepatch/discover.sh --input "$private/candidate-qualification.json" \
  --plan "$private/candidate-plan.json" --matrix "$private/candidate-matrix.json"

# HEAD is the only advertised ref; the writer already has the series base.
git bundle create "$out/candidate.bundle" HEAD "^$base"
printf 'candidate=%s\n' "$candidate" >> "$GITHUB_OUTPUT"
printf 'base=%s\n' "$base" >> "$GITHUB_OUTPUT"

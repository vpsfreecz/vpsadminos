#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ ${GITHUB_REPOSITORY:-} == vpsfreecz/vpsadminos && ${GITHUB_REF:-} == refs/heads/staging ]]
[[ ${KERNEL_RETENTION_WRITE:-} == true && $EXPECTED_FLEET_SHA256 =~ ^[0-9a-f]{64}$ ]]
[[ $BASE =~ ^[0-9a-f]{40}$ && $CANDIDATE =~ ^[0-9a-f]{40}$ ]]
[[ $GITHUB_RUN_ID =~ ^[0-9]+$ && $GITHUB_RUN_ATTEMPT =~ ^[0-9]+$ ]]
[[ $(git rev-parse HEAD) == "$BASE" ]]

private=$(mktemp -d)
trap 'rm -rf -- "$private"' EXIT
artifact="$RUNNER_TEMP/kernel-retention"
pruner=(python3 -B tools/kernel-retention.py)
remote=https://github.com/vpsfreecz/vpsadminos.git
ref="kernel-retention-candidate-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
workflow=kernel-entry-check.yml
check=kernel-entry-correctness
api="repos/$GITHUB_REPOSITORY"
# Keep the token in the credential helper environment, never in a URL.
remote_git=(git -c credential.helper= -c 'credential.helper=!gh auth git-credential')

staging_tip() {
  "${remote_git[@]}" ls-remote --exit-code "$remote" refs/heads/staging | cut -f1
}

verify_tree() {
  "${pruner[@]}" "$@" --base "$BASE" --candidate "$CANDIDATE" \
    --evidence "$artifact/evidence.json" --proof "$artifact/proof.json"
}

# Read only the bundle's advertised HEAD; never check out candidate code here.
git bundle verify "$artifact/candidate.bundle"
git -c fetch.writeCommitGraph=false fetch --no-tags "$artifact/candidate.bundle" HEAD
[[ $(git rev-parse FETCH_HEAD) == "$CANDIDATE" ]]
verify_tree verify-tree
[[ $(staging_tip) == "$BASE" ]]

# GITHUB_TOKEN pushes do not produce ordinary push-triggered checks.
existing=$("${remote_git[@]}" ls-remote "$remote" "refs/heads/$ref")
[[ -z $existing ]]
"${remote_git[@]}" push "$remote" "$CANDIDATE:refs/heads/$ref"
gh api --method POST "$api/actions/workflows/$workflow/dispatches" -f "ref=$ref" >/dev/null
run_id=
for ((i=0; i<30; i++)); do
  runs=$(gh api "$api/actions/workflows/$workflow/runs?event=workflow_dispatch&branch=$ref&head_sha=$CANDIDATE&per_page=10")
  run=$(jq -c --arg sha "$CANDIDATE" --arg ref "$ref" --arg repo "$GITHUB_REPOSITORY" '
    [.workflow_runs[] | select(.head_sha == $sha and .head_branch == $ref and
                               .head_repository.full_name == $repo and .event == "workflow_dispatch")]
    | if length == 0 then null elif length == 1 then .[0] else error("ambiguous check runs") end
  ' <<< "$runs")
  if jq -e '.status == "completed"' <<< "$run" >/dev/null; then
    run_id=$(jq -er 'select(.conclusion == "success") | .id | select(type == "number")' <<< "$run")
    break
  fi
  sleep 10
done
[[ $run_id =~ ^[0-9]+$ ]]

# Bind the expected named job to its GitHub Actions check run on this exact SHA.
check_id=$(gh api "$api/actions/runs/$run_id/jobs" | jq -er --arg name "$check" '
  [.jobs[] | select(.name == $name and .conclusion == "success")]
  | select(length == 1) | .[0].check_run_url | split("/") | last
')
[[ $check_id =~ ^[0-9]+$ ]]
gh api "$api/check-runs/$check_id" | jq -e --arg sha "$CANDIDATE" --arg name "$check" '
  .head_sha == $sha and .name == $name and .app.slug == "github-actions" and
  .status == "completed" and .conclusion == "success"
' >/dev/null

# Recompute on B, not on the candidate which no longer has retired keys.
[[ $(staging_tip) == "$BASE" ]]
"${pruner[@]}" collect --output "$private/fleet.json"
[[ $(staging_tip) == "$BASE" ]]
SECONDS=0
verify_tree recheck --fleet "$private/fleet.json" --as-of "$(date -u +%FT%T.%6NZ)" \
  --expected-fleet-sha256 "$EXPECTED_FLEET_SHA256" > "$private/recheck.json"
cat "$private/recheck.json"
deadline=$(jq -er '.fresh_until_ms | select(type == "number" and floor == .)' "$private/recheck.json")
remaining=$(( (deadline - $(date -u +%s%3N)) / 1000 ))
if (( SECONDS >= 10 || remaining < 1 )); then
  echo 'Fresh fleet evidence expired before the staging push.' >&2
  exit 1
fi
if (( remaining > 20 )); then remaining=20; fi

# Ordinary fast-forward only, no lease, forced update, rebase, or automatic retry.
if ! timeout "$remaining" "${remote_git[@]}" push "$remote" "$CANDIDATE:refs/heads/staging"; then
  tip=$(staging_tip) || exit 1
  if [[ $tip != "$CANDIDATE" ]]; then
    echo 'Push failed or could not be confirmed. Do not retry this transaction.' >&2
    exit 1
  fi
fi

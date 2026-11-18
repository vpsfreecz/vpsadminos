storage_operation_validate() {
  set -euo pipefail

  usage() {
    cat >&2 <<'EOF'
usage: storage validator --plan FILE --capture FILE --row-id ID \
       --state-dir DIR --runner-log FILE --semantic-log FILE \
       --runner-status STATUS --output FILE
EOF
    exit 2
  }

  fail() {
    echo "$EXPECTED_ORACLE_ID: $*" >&2
    exit 1
  }

  plan=
  capture=
  row_id=
  state_dir=
  runner_log=
  semantic_log=
  runner_status=
  output=

  while (($#)); do
    case "$1" in
      --capture)
        (($# >= 2)) || usage
        capture=$2
        shift 2
        ;;
      --output)
        (($# >= 2)) || usage
        output=$2
        shift 2
        ;;
      --plan)
        (($# >= 2)) || usage
        plan=$2
        shift 2
        ;;
      --row-id)
        (($# >= 2)) || usage
        row_id=$2
        shift 2
        ;;
      --runner-log)
        (($# >= 2)) || usage
        runner_log=$2
        shift 2
        ;;
      --runner-status)
        (($# >= 2)) || usage
        runner_status=$2
        shift 2
        ;;
      --semantic-log)
        (($# >= 2)) || usage
        semantic_log=$2
        shift 2
        ;;
      --state-dir)
        (($# >= 2)) || usage
        state_dir=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done

  [[ -n "$plan" && -n "$capture" && -n "$row_id" && -n "$state_dir" ]] || usage
  [[ -n "$runner_log" && -n "$semantic_log" && -n "$runner_status" && -n "$output" ]] || usage
  [[ "$runner_status" =~ ^[0-9]+$ ]] || fail "runner status is not an integer"
  [[ "$runner_status" == 0 ]] || fail "runner did not succeed"

  for input in "$plan" "$capture" "$runner_log" "$semantic_log"; do
    [[ -f "$input" && ! -L "$input" ]] || fail "input is not a regular non-symlink file: $input"
  done
  [[ -d "$state_dir" && ! -L "$state_dir" ]] || fail "state directory is invalid"
  state_root=$(readlink -e -- "$state_dir")
  runner_log=$(readlink -e -- "$runner_log")
  semantic_log=$(readlink -e -- "$semantic_log")
  [[ "$runner_log" == "$state_root/test.log" ]] || fail "runner log is outside its controller role"
  semantic_dir=$(dirname -- "$semantic_log")
  [[ $(dirname -- "$semantic_dir") == "$state_root" ]] || fail "semantic log is outside the state directory"
  [[ "${semantic_dir##*/}" == os-test-* && -d "$semantic_dir" && ! -L "$semantic_dir" ]] \
    || fail "semantic log result directory is invalid"
  [[ "${semantic_log##*/}" == test-runner.log ]] || fail "semantic log has an unexpected name"
  [[ "$semantic_log" != "$runner_log" ]] || fail "runner and semantic logs must be distinct"
  [[ $(dirname -- "$output") == "$state_dir" ]] || fail "output must be inside the state directory"
  [[ ! -e "$output" && ! -L "$output" ]] || fail "output already exists"
  [[ -f "$state_dir/runner.status" && ! -L "$state_dir/runner.status" ]] \
    || fail "runner.status is missing"
  [[ $(cat "$state_dir/runner.status") == "$runner_status" ]] \
    || fail "runner status file does not match"

  row=$(jq -cer --arg rowId "$row_id" '
    [.rows[] | select(.rowId == $rowId)]
    | if length == 1 then .[0] else error("row selection is not unique") end
  ' "$plan")

  jq -e \
    --arg rowId "$row_id" \
    --arg fixId "$EXPECTED_FIX_ID" \
    --arg oracleId "$EXPECTED_ORACLE_ID" \
    --arg adapter "$EXPECTED_ADAPTER" \
    --arg validator "$EXPECTED_VALIDATOR" '
    .schemaVersion == 1
    and .dormant == false
    and .selectedSets == 1
    and (.sets | length) == 1
    and .sets[0].id == "6.12.113.2"
    and .sets[0].kernelVersion == "6.12.113"
    and .sets[0].tipRelease == "6.12.113.2"
    and (.sets[0].members | map(.release)) == ["6.12.113.1", "6.12.113.2"]
    and ([.sets[0].oracles[] | select(.fixId == $fixId and .id == $oracleId)] | length) == 1
    and ([.rows[] | select(.rowId == $rowId)] | length) == 1
    and ([.rows[] | select(.scope == "set") | .oracleIds] | all(. == []))
    and ([.rows[] | select(.scope == "fix" and .oracleIds == [$oracleId])] | length) == 2
    and ([.rows[] | select(.scope == "fix" and .oracleIds == [$oracleId]) | .testAdapter]
      | all(. == $adapter))
    and ([.rows[] | select(.scope == "fix" and .oracleIds == [$oracleId]) | .validator]
      | all(. == $validator))
  ' "$plan" >/dev/null

  jq -e \
    --arg fixId "$EXPECTED_FIX_ID" \
    --arg oracleId "$EXPECTED_ORACLE_ID" \
    --arg adapter "$EXPECTED_ADAPTER" \
    --arg validator "$EXPECTED_VALIDATOR" '
    .scope == "fix"
    and .role == "operation-safety"
    and .profileId == ("fix/" + $fixId + "/" + $oracleId)
    and .oracleIds == [$oracleId]
    and .oracleShard == $oracleId
    and .supported == true
    and .expectedOutcome == "success"
    and (.platformId == "amd" or .platformId == "intel")
    and .platform.id == .platformId
    and .platform.runnerClass == .runnerClass
    and .platform.supported == true
    and .testAdapter == $adapter
    and .validator == $validator
  ' <<<"$row" >/dev/null

  jq -e --arg setId "$(jq -er '.setId' <<<"$row")" --slurpfile plan "$plan" '
    def sha: type == "string" and test("^[0-9a-f]{64}$");
    def nonempty: type == "string" and length > 0;
    .schemaVersion == 1
    and .rawBuildLogIdentity == "per-realization-only"
    and (.sourceRevision | nonempty)
    and (.flakeLockSha256 | sha)
    and .selectedSets == 1
    and (.sets | length) == 1
    and .sets[0].id == $setId
    and (.sets[0].members | map(.release)) == ["6.12.113.1", "6.12.113.2"]
    and (.sets[0].members | length) == 2
    and ([.sets[0].members[] | keys | sort] | all(. == ["audit", "identity", "release"]))
    and ([.sets[0].members[].identity | keys | sort] | all(. == [
      "closureSha256", "flakeLockSha256", "inputDigest", "inspectionSha256",
      "manifestSha256", "module", "moduleName", "moduleSha256", "producer",
      "sourceRevision", "targetId", "vermagic"
    ]))
    and (.sets[0].members | map(.release)) == ($plan[0].sets[0].members | map(.release))
    and ((.sets[0].members[0].identity.sourceRevision) as $sourceRevision
      | [.sets[0].members[].identity.sourceRevision] | all(. == $sourceRevision))
    and ((.sets[0].members[0].identity.flakeLockSha256) as $flakeLockSha256
      | [.sets[0].members[].identity.flakeLockSha256] | all(. == $flakeLockSha256))
  ' "$capture" >/dev/null

  grep -F '1 tests successful' "$runner_log" >/dev/null || fail "runner summary is missing"
  if grep -F 'tests should have succeeded' "$runner_log" >/dev/null; then
    fail "runner log contains a failure summary"
  fi
  noise='BUG:|kernel BUG at|WARNING:|Oops:|general protection fault|[Kk]ernel panic|blocked for more than|soft lockup|hard LOCKUP|([Rr][Cc][Uu]).*stall|livepatch.*(error|failed)|(ceph|libceph|NFS|NFSD|RPC):.*(fatal|error)'
  if grep -E "$noise" "$runner_log" >/dev/null; then
    fail "runner log contains fatal kernel or storage-service noise"
  fi
  if grep -E "$noise" "$semantic_log" >/dev/null; then
    fail "semantic log contains fatal kernel or storage-service noise"
  fi

  marker_prefix='VPSADMINOS_LIVEPATCH_ORACLE_RESULT '
  mapfile -t marker_lines < <(grep -F "$marker_prefix" "$semantic_log" || true)
  [[ ${#marker_lines[@]} -eq 1 ]] || fail "expected exactly one oracle result marker"
  marker_json=${marker_lines[0]#*"$marker_prefix"}

  marker_tmp=$(mktemp "$state_dir/.storage-oracle-marker.XXXXXX")
  result_tmp=$(mktemp "$state_dir/.storage-oracle-result.XXXXXX")
  cleanup() {
    rm -f -- "$marker_tmp" "$result_tmp"
  }
  trap cleanup EXIT HUP INT TERM
  chmod 0600 "$marker_tmp" "$result_tmp"
  printf '%s\n' "$marker_json" > "$marker_tmp"

  jq -e \
    --argjson row "$row" \
    --arg oracleId "$EXPECTED_ORACLE_ID" \
    --slurpfile capture "$capture" '
    .schemaVersion == 1
    and .oracleId == $oracleId
    and .rowId == $row.rowId
    and .setId == $row.setId
    and .platformId == $row.platformId
    and .runnerClass == $row.runnerClass
    and .release == "6.12.113.2"
    and .nativeRelease == "6.12.113"
    and .members == ($capture[0].sets[0].members | map(.identity))
    and (.workload.operations | type == "number" and floor == . and . > 0)
    and (.workload.integritySha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and .workload.operation == $oracleId
    and .forward == {release: "6.12.113.2", converged: true}
    and .reverse == {release: "6.12.113", modulesRemoved: true}
    and .kernelHealth == "clean"
  ' "$marker_tmp" >/dev/null

  jq -n \
    --arg rowId "$row_id" \
    --arg setId "$(jq -er '.setId' <<<"$row")" \
    --arg profileId "$(jq -er '.profileId' <<<"$row")" \
    --arg fixId "$EXPECTED_FIX_ID" \
    --arg oracleId "$EXPECTED_ORACLE_ID" \
    --arg markerSha256 "$(sha256sum "$marker_tmp" | cut -d' ' -f1)" \
    --argjson runnerStatus "$runner_status" \
    --slurpfile marker "$marker_tmp" '
    {
      schemaVersion: 1,
      rowId: $rowId,
      setId: $setId,
      profileId: $profileId,
      runnerStatus: $runnerStatus,
      accepted: true,
      validator: {
        id: $oracleId,
        fixId: $fixId,
        status: "accepted",
        markerSha256: $markerSha256,
        platformId: $marker[0].platformId,
        operations: $marker[0].workload.operations,
        integritySha256: $marker[0].workload.integritySha256
      }
    }
  ' > "$result_tmp"

  mv -T -- "$result_tmp" "$output"
  trap - EXIT HUP INT TERM
  rm -f -- "$marker_tmp"
}

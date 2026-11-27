{
  pkgs,
  plan,
  ciTools,
}:
let
  set = builtins.head (builtins.filter (set: set.id == "6.12.48.1") plan.sets);
  row = builtins.head (
    builtins.filter (row: builtins.elem "nfsd-sequence-operation-safety" row.oracleIds) plan.rows
  );
  oracle = builtins.head (import ./oracles/nfsd-sequence-reply-preflight.nix).oracles;
  sha = builtins.concatStringsSep "" (builtins.genList (_: "a") 64);
  identity = {
    producer = "/nix/store/00000000000000000000000000000000-synthetic-producer";
    module = "/nix/store/00000000000000000000000000000000-synthetic-producer/test.ko";
    moduleName = "synthetic_livepatch";
    moduleSha256 = sha;
    targetId = "synthetic-target";
    inputDigest = sha;
    manifestSha256 = sha;
    inspectionSha256 = sha;
    closureSha256 = sha;
    vermagic = "6.12.48 synthetic";
    sourceRevision = plan.sourceRevision;
    flakeLockSha256 = sha;
  };
  capture = {
    schemaVersion = 1;
    sourceRevision = plan.sourceRevision;
    flakeLockSha256 = sha;
    rawBuildLogIdentity = "per-realization-only";
    sets = [
      {
        id = set.id;
        members = [
          {
            release = (builtins.head set.members).release;
            inherit identity;
            audit = { };
          }
        ];
      }
    ];
  };
  helper = import ./helpers/nfsd-sequence-reply-preflight.nix {
    inherit
      capture
      oracle
      plan
      pkgs
      row
      ;
    qualificationSet = set;
  };
  operation =
    builtins.head
      ((builtins.head helper.modules) { inherit pkgs; }).environment.systemPackages;
  planFile = pkgs.writeText "nfsd-plan.json" (builtins.toJSON plan);
  captureFile = pkgs.writeText "nfsd-capture.json" (builtins.toJSON capture);
  oracleFile = pkgs.writeText "nfsd-oracle.rb" helper.oracleScripts.operation-safety;
in
pkgs.runCommand "livepatch-qualification-6.12.48.1-check" { nativeBuildInputs = [ ciTools ]; } ''
  ${pkgs.bash}/bin/bash -n ${operation}/bin/nfsd-sequence-operation
  ${pkgs.bash}/bin/bash -n ${./validators/nfsd-sequence-reply-preflight.sh}
  ${pkgs.ruby}/bin/ruby -c ${oracleFile}
  grep -F -- 'timeout --kill-after=5 150' ${operation}/bin/nfsd-sequence-operation
  grep -F -- 'readiness phase=%s elapsed=%ss grace=%s lease=%s' \
    ${operation}/bin/nfsd-sequence-operation
  grep -F -- 'mv -T "$state/readiness.$$" "$state/readiness"' \
    ${operation}/bin/nfsd-sequence-operation
  grep -F -- 'readiness_emit seed-readiness' ${operation}/bin/nfsd-sequence-operation
  grep -F -- 'readiness_emit ready' ${operation}/bin/nfsd-sequence-operation
  grep -F -- 'readiness failed phase=%s status=%s elapsed=%ss grace=%s lease=%s' \
    ${operation}/bin/nfsd-sequence-operation
  grep -F -- '/proc/fs/nfsd/nfsv4gracetime' ${operation}/bin/nfsd-sequence-operation
  grep -F -- '/proc/fs/nfsd/nfsv4leasetime' ${operation}/bin/nfsd-sequence-operation
  grep -F -- 'findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS' \
    ${operation}/bin/nfsd-sequence-operation
  grep -F -- 'nfsd-threads=' ${operation}/bin/nfsd-sequence-operation
  grep -F -- 'dmesg-tail:' ${operation}/bin/nfsd-sequence-operation
  grep -F -- "machine.succeeds('nfsd-sequence-operation prepare', timeout: 210)" \
    ${oracleFile}
  readiness_timeout=150
  prepare_timeout=210
  mount_timeout=30
  diagnostic_overhead=30
  test "$prepare_timeout" -eq \
    "$((mount_timeout + readiness_timeout + diagnostic_overhead))"
  mkdir "$out"
  cp ${planFile} "$out/plan.json"
  cp ${captureFile} "$out/capture.json"
  cp ${oracleFile} "$out/oracle.rb"
  jq -cn --argjson row '${builtins.toJSON row}' --slurpfile capture ${captureFile} '{
    schemaVersion: 1, oracleId: "nfsd-sequence-operation-safety",
    rowId: $row.rowId, setId: $row.setId,
    platformId: $row.platformId, runnerClass: $row.runnerClass,
    release: "6.12.48.1", nativeRelease: "6.12.48",
    identity: $capture[0].sets[0].members[0].identity,
    workload: {
      protocol: "4.1", transport: "tcp", mounts: 1, freshMounts: 2,
      continuous: true, integritySha256: $capture[0].flakeLockSha256,
      progress: {native: 1, forward: 2, beforeReverse: 3, reverse: 4, final: 5}
    },
    forward: {enabled: 1, transition: 0, replace: 0, release: "6.12.48.1"},
    reverse: {moduleRemoved: true, release: "6.12.48"},
    cleanup: {workerStopped: true, mountsRemoved: true, serverStopped: true},
    kernelHealth: "clean"
  }' > marker.json

  validate() {
    local label=$1
    local marker=$2
    local selected_plan=''${3-${planFile}}
    local selected_capture=''${4-${captureFile}}
    local state="$TMPDIR/$label"
    mkdir -p "$state/os-test-nfsd"
    printf '0\n' > "$state/runner.status"
    printf '1 tests successful\n' > "$state/test.log"
    { printf 'VPSADMINOS_LIVEPATCH_ORACLE_RESULT '; cat "$marker"; } \
      > "$state/os-test-nfsd/test-runner.log"
    ${pkgs.bash}/bin/bash ${./validators/nfsd-sequence-reply-preflight.sh} \
      --plan "$selected_plan" --capture "$selected_capture" --row-id '${row.rowId}' \
      --state-dir "$state" --runner-log "$state/test.log" \
      --semantic-log "$state/os-test-nfsd/test-runner.log" --runner-status 0 \
      --output "$state/result.json"
  }
  validate valid marker.json
  jq -e '.accepted == true and .validator.status == "accepted"' "$TMPDIR/valid/result.json"
  for mutation in \
    '.workload.progress.forward = .workload.progress.native' \
    '.workload.progress.reverse = .workload.progress.beforeReverse' \
    '.workload.continuous = false' \
    '.workload.integritySha256 = "bad"' \
    '.identity.moduleSha256 = "bad"' \
    '.forward.transition = 1' \
    '.reverse.moduleRemoved = false' \
    '.cleanup.serverStopped = false' \
    '.platformId = "intel"' \
    '.rowId = "other"'; do
    jq -c "$mutation" marker.json > bad-marker.json
    label="refuse-$RANDOM"
    if validate "$label" bad-marker.json; then
      echo "accepted invalid marker: $mutation" >&2
      exit 1
    fi
    test ! -e "$TMPDIR/$label/result.json"
  done
  jq '(.sets[] | select(.id == "6.12.48.1") | .members[0].kernelVersion) = "other"' \
    ${planFile} > bad-plan.json
  if validate wrong-target marker.json bad-plan.json; then exit 1; fi
  jq '.sets[0].members[0].release = "other"' ${captureFile} > bad-capture.json
  if validate wrong-capture marker.json ${planFile} bad-capture.json; then exit 1; fi
  printf '%s {}\n' "$(cat marker.json)" > multiple-values.json
  if validate multiple-values multiple-values.json; then exit 1; fi
  { cat marker.json; printf 'VPSADMINOS_LIVEPATCH_ORACLE_RESULT '; cat marker.json; } > duplicate-marker.json
  if validate duplicate-marker duplicate-marker.json; then exit 1; fi
  printf '{invalid-json\n' > malformed-marker.json
  if validate malformed-marker malformed-marker.json; then exit 1; fi
  printf 'NFSv4.1 operation-safety validator acceptance/refusal checks passed\n' > "$out/result"
''

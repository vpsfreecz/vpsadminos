#!/usr/bin/env bash

set -euo pipefail

nfs_validator=$1
nfs_oracle_script=$2
nfs_plan=$3
nfs_capture=$4
ruby=$5
profile_runner=$6
validator=$7
profile_fixture=$8
reverse_fixture=$9
# The release-specific handoff cases use a regular config written by the fake runner.
profile_store_config=
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

[[ -x "$nfs_validator" ]]
[[ -f "$nfs_oracle_script" && ! -L "$nfs_oracle_script" ]]
[[ -f "$nfs_plan" && ! -L "$nfs_plan" ]]
[[ -f "$nfs_capture" && ! -L "$nfs_capture" ]]
jq -e '
  .counts.plannedRows == 10
  and .counts.matrixRows == 10
  and ([.rows[] | select(.role == "aged-transition")] | length) == 2
  and ([.rows[] | select(.role == "aged-transition") | .aging] | all(
    . == {
      evidenceClass: "release",
      dwellSeconds: 1800,
      developmentDwellSeconds: 300,
      releaseDwellSeconds: 1800,
      checkpointSeconds: 60
    }
  ))
' "$nfs_plan" >/dev/null

source "$reverse_fixture"
extract_method F9_NFS_COMPLETED_DISABLE_BEGIN F9_NFS_COMPLETED_DISABLE_END \
  "$nfs_oracle_script" "$work/nfs-completed-disable.rb"
extract_method F9_NFS_REVERSE_BOUNDARY_BEGIN F9_NFS_REVERSE_BOUNDARY_END \
  "$nfs_oracle_script" "$work/nfs-reverse-boundary.rb"

{
  write_reverse_fixture
  cat <<'RUBY'
class NfsConsumer
RUBY
  cat "$work/nfs-completed-disable.rb"
  cat <<'RUBY'
end

Dir.mktmpdir('livepatch-nfs-reverse-convergence-') do |root|
  module_name = 'lp_612113_1_test'
  machine = PredicateMachine.new(root, module_name)
  nfs = NfsConsumer.new
  check_completed_disable(machine, 'NFS') do
    nfs.wait_nfs_completed_disable(machine, machine.patch_path.to_s, module_name)
  end
end

nfs_boundary = File.binread(ARGV.fetch(0))
positions = [
  nfs_boundary.index('echo 0 >'),
  nfs_boundary.index('wait_nfs_completed_disable'),
  nfs_boundary.index('rmmod'),
  nfs_boundary.index('test ! -d #{Shellwords.escape(patch_dir)} && test ! -d /sys/module'),
  nfs_boundary.index('uname -r'),
]
raise 'NFS reverse boundary is incomplete' if positions.any?(&:nil?)
raise 'NFS reverse boundary order mismatch' unless positions == positions.sort && positions.uniq.length == positions.length

puts 'NFS completed-disable convergence matrix passed'
RUBY
} >"$work/nfs-reverse-convergence.rb"

F9_TEST_BASH=$BASH "$ruby" -c "$work/nfs-reverse-convergence.rb" >/dev/null
F9_TEST_BASH=$BASH "$ruby" "$work/nfs-reverse-convergence.rb" \
  "$work/nfs-reverse-boundary.rb"

awk '
  /F6_NFS_CAPTURE_RELATION_BEGIN/ { capture = 1; next }
  /F6_NFS_CAPTURE_RELATION_END/ { capture = 0 }
  capture { print }
' "$nfs_oracle_script" >"$work/nfs-capture-relation-method.rb"
[[ -s "$work/nfs-capture-relation-method.rb" ]]

{
  printf 'require "json"\n\nclass NfsCaptureRelation\n'
  cat "$work/nfs-capture-relation-method.rb"
  cat <<'RUBY'
end

def deep_copy(value)
Marshal.load(Marshal.dump(value))
end

def refuse(label)
yield
rescue KeyError, RuntimeError
return
else
raise "NFS capture relation unexpectedly accepted #{label}"
end

plan = JSON.parse(File.binread(ARGV.fetch(0)))
capture = JSON.parse(File.binread(ARGV.fetch(1)))
planned_set = plan.fetch('sets').fetch(0)
captured_set = capture.fetch('sets').fetch(0)
relation = NfsCaptureRelation.new
relation.validate_nfs_capture_relation(planned_set, captured_set)

missing_target = deep_copy(planned_set)
missing_target.fetch('members').fetch(0).delete('kernelVersion')
refuse('missing planned member target') do
relation.validate_nfs_capture_relation(missing_target, captured_set)
end

mismatched_target = deep_copy(planned_set)
mismatched_target.fetch('members').fetch(0)['kernelVersion'] = '6.12.114'
refuse('mismatched planned member target') do
relation.validate_nfs_capture_relation(mismatched_target, captured_set)
end

mismatched_release = deep_copy(captured_set)
mismatched_release.fetch('members').fetch(0)['release'] = '6.12.113.2'
refuse('capture/plan release mismatch') do
relation.validate_nfs_capture_relation(planned_set, mismatched_release)
end

two_member_plan = deep_copy(planned_set)
two_member_plan.fetch('members') << deep_copy(two_member_plan.fetch('members').fetch(0)).merge(
'release' => '6.12.113.2',
)
reordered_capture = deep_copy(captured_set)
reordered_capture.fetch('members') << deep_copy(reordered_capture.fetch('members').fetch(0)).merge(
'release' => '6.12.113.2',
)
reordered_capture['members'].reverse!
refuse('reordered members') do
relation.validate_nfs_capture_relation(two_member_plan, reordered_capture)
end

extra_capture = deep_copy(captured_set)
extra_capture.fetch('members') << deep_copy(extra_capture.fetch('members').fetch(0))
refuse('extra captured member') do
relation.validate_nfs_capture_relation(planned_set, extra_capture)
end

puts 'NFS livepatch capture relation passed'
RUBY
} >"$work/nfs-capture-relation.rb"

"$ruby" "$work/nfs-capture-relation.rb" "$nfs_plan" "$nfs_capture"

cat >"$work/nfs-count-admission.rb" <<'RUBY'
require 'json'

class AdmissionReached < RuntimeError
end

class AdmissionRefused < RuntimeError
end

class EqualityMatcher
def initialize(expected)
  @expected = expected
end

def match(actual)
  return if actual == @expected

  raise AdmissionRefused, "expected #{actual.inspect} to equal #{@expected.inspect}"
end
end

class Expectation
def initialize(actual)
  @actual = actual
end

def to(matcher)
  matcher.match(@actual)
end
end

class AdmissionMachine
def succeeds(_command)
  raise AdmissionReached, 'NFS operation boundary reached'
end
end

class OracleAdmission
def initialize(plan, capture)
  @plan = plan
  @capture = capture
end

def eq(expected)
  EqualityMatcher.new(expected)
end

def expect(actual)
  Expectation.new(actual)
end

def machine
  @machine ||= AdmissionMachine.new
end

def run(source, source_path)
  instance_eval(source, source_path, 1)
end
end

source_path, plan_path, capture_path, platform_id, expected = ARGV
plan = JSON.parse(File.binread(plan_path))
capture = JSON.parse(File.binread(capture_path))
rows = plan.fetch('rows').select do |row|
row.fetch('scope') == 'fix' && row.fetch('platformId') == platform_id
end
raise "#{platform_id} NFS row is not unique" unless rows.length == 1

Object.const_set(:ROW, rows.fetch(0))
begin
OracleAdmission.new(plan, capture).run(File.binread(source_path), source_path)
rescue AdmissionReached
raise "#{platform_id} old-count plan reached NFS operations" unless expected == 'accept'
rescue AdmissionRefused => error
raise if expected != 'refuse'
raise "#{platform_id} refusal was not the ten-row admission: #{error.message}" unless
  error.message == 'expected 8 to equal 10'
else
raise "#{platform_id} NFS admission did not reach its operation boundary"
end
RUBY

jq '.counts.matrixRows = 8 | .counts.plannedRows = 8' \
  "$nfs_plan" >"$work/nfs-plan-old-counts.json"
for platform_id in amd intel; do
  "$ruby" "$work/nfs-count-admission.rb" \
    "$nfs_oracle_script" "$nfs_plan" "$nfs_capture" "$platform_id" accept
  "$ruby" "$work/nfs-count-admission.rb" \
    "$nfs_oracle_script" "$work/nfs-plan-old-counts.json" "$nfs_capture" \
    "$platform_id" refuse
done
printf 'NFS rendered ten-row count admission passed\n'

nfs_row=$(jq -cer '[.rows[] | select(.scope == "fix" and .platformId == "amd")]
  | if length == 1 then .[0] else error("AMD NFS row is not unique") end' "$nfs_plan")
nfs_row_id=$(jq -er '.rowId' <<<"$nfs_row")
nfs_other_row_id=$(jq -er '.rows[] | select(.scope == "fix" and .platformId == "intel") | .rowId' "$nfs_plan")

jq -cn \
  --argjson row "$nfs_row" \
  --slurpfile plan "$nfs_plan" \
  --slurpfile capture "$nfs_capture" '
    {
      schemaVersion: 1,
      oracleId: "nfs-client-operation-safety",
      platformId: $row.platformId,
      runnerClass: $row.runnerClass,
      rowId: $row.rowId,
      setId: $row.setId,
      release: $capture[0].sets[0].members[0].release,
      nativeRelease: $plan[0].sets[0].kernelVersion,
      identity: $capture[0].sets[0].members[0].identity,
      workload: {
        mounts: 2,
        freshMounts: 2,
        operations: 1,
        integritySha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      quiescence: {
        mountCreation: true,
        finalUnmount: true,
        shutdownSysfsWrites: true
      },
      forward: {
        enabled: 1,
        transition: 0,
        replace: 0,
        release: $capture[0].sets[0].members[0].release
      },
      reverse: {
        moduleRemoved: true,
        release: $plan[0].sets[0].kernelVersion
      },
      kernelHealth: "clean"
    }
  ' >"$work/nfs-marker.json"

run_nfs_validator() {
  local label=$1
  local plan_file=$2
  local capture_file=$3
  local selected_row=$4
  local marker_file=$5
  local state="$work/nfs-$label"
  local result_state="$state/os-test-nfs"

  mkdir -p "$result_state"
  printf '0\n' >"$state/runner.status"
  printf '1 tests successful\n' >"$state/test.log"
  {
    printf 'VPSADMINOS_LIVEPATCH_ORACLE_RESULT '
    cat "$marker_file"
    printf '\n'
  } >"$result_state/test-runner.log"
  "$nfs_validator" \
    --plan "$plan_file" \
    --capture "$capture_file" \
    --row-id "$selected_row" \
    --state-dir "$state" \
    --runner-log "$state/test.log" \
    --semantic-log "$result_state/test-runner.log" \
    --runner-status 0 \
    --output "$state/result.json"
}

expect_nfs_refuse() {
  local label=$1
  shift
  if run_nfs_validator "$label" "$@" >"$work/nfs-$label.stdout" 2>"$work/nfs-$label.stderr"; then
    echo "NFS validator refusal case unexpectedly succeeded: $label" >&2
    exit 1
  fi
  [[ ! -e "$work/nfs-$label/result.json" ]]
}

run_nfs_validator valid "$nfs_plan" "$nfs_capture" "$nfs_row_id" "$work/nfs-marker.json"
jq -e '.schemaVersion == 1 and .accepted == true and .validator.status == "accepted"' \
  "$work/nfs-valid/result.json" >/dev/null

jq '.sets[0].members[0].kernelVersion = "6.12.114"' "$nfs_plan" >"$work/nfs-plan-target-mismatch.json"
jq 'del(.sets[0].members[0].kernelVersion)' "$nfs_plan" >"$work/nfs-plan-target-missing.json"
jq '.sets[0].members[0].release = "6.12.113.2"' "$nfs_capture" >"$work/nfs-capture-release-mismatch.json"
jq '.identity.moduleSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$work/nfs-marker.json" >"$work/nfs-marker-identity-mismatch.json"
jq '.platformId = "intel"' "$work/nfs-marker.json" >"$work/nfs-marker-wrong-platform.json"
printf '{invalid-json\n' >"$work/nfs-marker-malformed.json"

expect_nfs_refuse target-mismatch "$work/nfs-plan-target-mismatch.json" "$nfs_capture" \
  "$nfs_row_id" "$work/nfs-marker.json"
expect_nfs_refuse target-missing "$work/nfs-plan-target-missing.json" "$nfs_capture" \
  "$nfs_row_id" "$work/nfs-marker.json"
expect_nfs_refuse release-mismatch "$nfs_plan" "$work/nfs-capture-release-mismatch.json" \
  "$nfs_row_id" "$work/nfs-marker.json"
expect_nfs_refuse identity-mismatch "$nfs_plan" "$nfs_capture" \
  "$nfs_row_id" "$work/nfs-marker-identity-mismatch.json"
expect_nfs_refuse wrong-row "$nfs_plan" "$nfs_capture" \
  "$nfs_other_row_id" "$work/nfs-marker.json"
expect_nfs_refuse wrong-platform "$nfs_plan" "$nfs_capture" \
  "$nfs_row_id" "$work/nfs-marker-wrong-platform.json"
expect_nfs_refuse malformed-marker "$nfs_plan" "$nfs_capture" \
  "$nfs_row_id" "$work/nfs-marker-malformed.json"

printf 'NFS livepatch validator matrix passed\n'

source "$profile_fixture"
mkdir -p \
  "$profile_root/os/livepatches/batches/6.12.113/1/qualification/validators" \
  "$profile_root/os/livepatches/batches/6.12.113.1/qualification/validators"
ln -s "$nfs_validator" \
  "$profile_root/os/livepatches/batches/6.12.113/1/qualification/validators/nfs-sysfs-client-lifetime.sh"
ln -s "$nfs_validator" \
  "$profile_root/os/livepatches/batches/6.12.113.1/qualification/validators/nfs-sysfs-client-lifetime.sh"

run_profile_case nfs-success \
  "$nfs_plan" "$nfs_capture" "$nfs_row_id" \
  "$work/nfs-marker.json" VPSADMINOS_LIVEPATCH_ORACLE_RESULT regular-config
jq -e '.accepted == true and .validator.id == "nfs-client-operation-safety"' \
  "$work/profile-nfs-success/result.json" >/dev/null
[[ $(cat "$work/profile-nfs-success/selector.txt") == \
  "kernel/livepatch-fix@$nfs_row_id" ]]
jq -e '
  .template == "kernel/livepatch-fix"
  and .testAdapter
    == "os/livepatches/batches/6.12.113/1/qualification/helpers/nfs-sysfs-client-lifetime.nix"
' <<<"$nfs_row" >/dev/null

jq --arg rowId "$nfs_row_id" '
  (.rows[] | select(.rowId == $rowId) | .validator)
    = "os/livepatches/batches/6.12.113.1/qualification/validators/nfs-sysfs-client-lifetime.sh"
' "$nfs_plan" >"$work/nfs-plan-flat-validator.json"
expect_profile_refuse flat-validator-path \
  "$work/nfs-plan-flat-validator.json" "$nfs_capture" "$nfs_row_id" \
  "$work/nfs-marker.json" VPSADMINOS_LIVEPATCH_ORACLE_RESULT regular-config

jq --arg rowId "$nfs_row_id" '
  (.rows[] | select(.rowId == $rowId) | .validator)
    = "os/livepatches/batches/6.12.113/1/qualification/validators/../validators/nfs-sysfs-client-lifetime.sh"
' "$nfs_plan" >"$work/nfs-plan-traversal-validator.json"
expect_profile_refuse traversal-validator-path \
  "$work/nfs-plan-traversal-validator.json" "$nfs_capture" "$nfs_row_id" \
  "$work/nfs-marker.json" VPSADMINOS_LIVEPATCH_ORACLE_RESULT regular-config

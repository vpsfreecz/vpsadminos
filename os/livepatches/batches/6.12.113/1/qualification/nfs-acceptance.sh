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
  . as $plan
  | .sets[0] as $set
  | .counts.catalogReleases == ($plan.releases | length)
  and .counts.normalizedReleases == ($plan.releases | length)
  and .counts.plannedMembers == ($set.members | length)
  and .counts.activeOracles == ($set.oracleIds | length)
  and .counts.coverageTuples == ($plan.coverage | length)
  and .counts.plannedRows == ($plan.rows | length)
  and .counts.matrixRows == ($plan.matrix.include | length)
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
extract_method D7_NFS_STACK_LIFECYCLE_BEGIN D7_NFS_STACK_LIFECYCLE_END \
  "$nfs_oracle_script" "$work/nfs-stack-lifecycle.rb"

{
  write_reverse_fixture
  cat <<'RUBY'
class NfsConsumer
RUBY
  cat "$work/nfs-completed-disable.rb"
  cat "$work/nfs-stack-lifecycle.rb"
  cat <<'RUBY'
end

class NfsStackMachine
  attr_reader :events

  def initialize
    @events = []
  end

  def succeeds(command, timeout: nil)
    raise 'unexpected NFS succeeds timeout' unless [60, nil].include?(timeout)

    case command
    when /\Ainsmod /
      events << [:insmod, Shellwords.split(command).last]
    when /echo 0 > \/sys\/kernel\/livepatch\/([^\/]+)\/enabled/
      events << [:disable, Regexp.last_match(1)]
    when /\Armmod /
      events << [:rmmod, Shellwords.split(command).last]
    when /uname -r/
      events << [:release, Shellwords.split(command).last]
    else
      raise "unexpected NFS succeeds command: #{command}"
    end
    ['', '']
  end

  def wait_until_succeeds(command, timeout:)
    raise 'unexpected NFS wait timeout' unless timeout == 180

    event =
      if command.include?('enabled')
        [:forward_converged, command.match(%r{/sys/kernel/livepatch/([^/ ]+)})&.captures&.first]
      elsif command.include?('test -d /sys/module/')
        [:completed_disable, command.match(%r{/sys/module/([^ ]+)})&.captures&.first]
      elsif command.include?('test ! -d /sys/module/')
        [:removed, command.match(%r{/sys/module/([^ ]+)})&.captures&.first]
      else
        raise "unexpected NFS wait command: #{command}"
      end
    raise "NFS wait command did not identify a module: #{command}" if event.last.nil?

    events << event
    ['', '']
  end
end

Dir.mktmpdir('livepatch-nfs-reverse-convergence-') do |root|
  module_name = 'lp_612113_1_test'
  machine = PredicateMachine.new(root, module_name)
  nfs = NfsConsumer.new
  check_completed_disable(machine, 'NFS') do
    nfs.wait_nfs_completed_disable(machine, machine.patch_path.to_s, module_name)
  end
end

nfs = NfsConsumer.new
one_member = [{
  release: '6.12.113.1',
  module_path: '/nix/store/synthetic-one.ko',
  module_name: 'lp_612113_1_one',
  patch_dir: '/sys/kernel/livepatch/lp_612113_1_one',
}]
two_members = one_member + [{
  release: '6.12.113.2',
  module_path: '/nix/store/synthetic-two.ko',
  module_name: 'lp_612113_2_two',
  patch_dir: '/sys/kernel/livepatch/lp_612113_2_two',
}]

[one_member, two_members].each do |members|
  machine = NfsStackMachine.new
  forward = nfs.load_nfs_set(machine, members)
  reverse = nfs.reverse_nfs_set(machine, members, '6.12.113')
  expected_forward = members.map do |member|
    {release: member.fetch(:release), enabled: 1, transition: 0, replace: 0}
  end
  expected_reverse = members.each_index.reverse_each.map do |index|
    {
      removedRelease: members.fetch(index).fetch(:release),
      release: index.zero? ? '6.12.113' : members.fetch(index - 1).fetch(:release),
      moduleRemoved: true,
    }
  end
  expected_events = members.flat_map do |member|
    [
      [:insmod, member.fetch(:module_path)],
      [:forward_converged, member.fetch(:module_name)],
      [:release, member.fetch(:release)],
    ]
  end
  expected_events += members.each_index.reverse_each.flat_map do |index|
    member = members.fetch(index)
    predecessor = index.zero? ? '6.12.113' : members.fetch(index - 1).fetch(:release)
    [
      [:disable, member.fetch(:module_name)],
      [:completed_disable, member.fetch(:module_name)],
      [:rmmod, member.fetch(:module_name)],
      [:removed, member.fetch(:module_name)],
      [:release, predecessor],
    ]
  end
  raise 'NFS forward observations mismatch' unless forward == expected_forward
  raise 'NFS reverse observations mismatch' unless reverse == expected_reverse
  raise "NFS stack lifecycle order mismatch: #{machine.events.inspect}" unless
    machine.events == expected_events
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
two_member_plan['id'] = '6.12.113.2'
two_member_plan['tipRelease'] = '6.12.113.2'
two_member_plan.fetch('members') << deep_copy(two_member_plan.fetch('members').fetch(0)).merge(
  'release' => '6.12.113.2',
  'releaseOrdinal' => 2,
  'predecessorRelease' => '6.12.113.1',
)
two_member_capture = deep_copy(captured_set)
two_member_capture.fetch('members') << deep_copy(two_member_capture.fetch('members').fetch(0)).merge(
  'release' => '6.12.113.2',
)
relation.validate_nfs_capture_relation(two_member_plan, two_member_capture)

missing_capture = deep_copy(two_member_capture)
missing_capture.fetch('members').pop
refuse('missing captured member') do
  relation.validate_nfs_capture_relation(two_member_plan, missing_capture)
end

reordered_capture = deep_copy(two_member_capture)
reordered_capture['members'].reverse!
refuse('reordered members') do
  relation.validate_nfs_capture_relation(two_member_plan, reordered_capture)
end

extra_capture = deep_copy(two_member_capture)
extra_capture.fetch('members') << deep_copy(extra_capture.fetch('members').fetch(0)).merge(
  'release' => '6.12.113.3',
)
refuse('extra captured member') do
  relation.validate_nfs_capture_relation(two_member_plan, extra_capture)
end

puts 'NFS livepatch capture relation passed'
RUBY
  } >"$work/nfs-capture-relation.rb"

  "$ruby" "$work/nfs-capture-relation.rb" "$nfs_plan" "$nfs_capture"

  "$ruby" -c "$nfs_oracle_script" >/dev/null

  jq '
    . as $source
    | ($source.rows | map(select(
        .scope == "fix"
        and .oracleIds == ["nfs-client-operation-safety"]
      ))) as $nfsRows
    | ($nfsRows | map(
        .setId = "6.12.113.2"
        | .rowId = (
            "6.12.113.2--fix-synthetic-successor-synthetic-successor-oracle--"
            + .platformId
          )
        | .profileId = "fix/synthetic-successor/synthetic-successor-oracle"
        | .role = "fixed-path"
        | .oracleIds = ["synthetic-successor-oracle"]
        | .oracleShard = "synthetic-successor-oracle"
        | .testAdapter
          = "os/livepatches/batches/6.12.113/2/qualification/helpers/synthetic-successor.nix"
        | .validator
          = "os/livepatches/batches/6.12.113/2/qualification/validators/synthetic-successor.sh"
      )) as $successorRows
    | .releases += [
        (.releases[0]
          | .release = "6.12.113.2"
          | .releaseOrdinal = 2)
      ]
    | .sets[0].id = "6.12.113.2"
    | .sets[0].tipRelease = "6.12.113.2"
    | .sets[0].members += [
        (.sets[0].members[0]
          | .release = "6.12.113.2"
          | .releaseOrdinal = 2
          | .predecessorRelease = "6.12.113.1"
          | .producerAttr = "livepatch-6.12.113.2"
          | .fixIds = ["synthetic-successor"]
          | .oracleIds = ["synthetic-successor-oracle"])
      ]
    | .sets[0].oracleIds += ["synthetic-successor-oracle"]
    | .sets[0].oracles += [
        (.sets[0].oracles[0]
          | .fixId = "synthetic-successor"
          | .id = "synthetic-successor-oracle"
          | .role = "fixed-path"
          | .testAdapter
            = "os/livepatches/batches/6.12.113/2/qualification/helpers/synthetic-successor.nix"
          | .validator
            = "os/livepatches/batches/6.12.113/2/qualification/validators/synthetic-successor.sh")
      ]
    | .rows |= map(
        .setId = "6.12.113.2"
        | .rowId |= sub("^6\\.12\\.113\\.1--"; "6.12.113.2--")
      )
    | .rows += $successorRows
    | .coverage |= map(
        .setId = "6.12.113.2"
        | .rowId |= sub("^6\\.12\\.113\\.1--"; "6.12.113.2--")
      )
    | .coverage += ($successorRows | map({
        oracleId: .oracleIds[0],
        platformId,
        profileId,
        rowId,
        setId
      }))
    | .matrix.include |= map(
        .setId = "6.12.113.2"
        | .rowId |= sub("^6\\.12\\.113\\.1--"; "6.12.113.2--")
      )
    | .matrix.include += ($successorRows | map({
        expectedOutcome,
        profileId,
        rowId,
        runnerClass,
        setId,
        timeoutClass
      }))
    | .counts.catalogReleases = (.releases | length)
    | .counts.normalizedReleases = (.releases | length)
    | .counts.plannedMembers = (.sets[0].members | length)
    | .counts.activeOracles = (.sets[0].oracleIds | length)
    | .counts.coverageTuples = (.coverage | length)
    | .counts.plannedRows = (.rows | length)
    | .counts.matrixRows = (.matrix.include | length)
  ' "$nfs_plan" >"$work/nfs-plan-two.json"

  jq '
    .sets[0].id = "6.12.113.2"
    | .sets[0].members += [
        (.sets[0].members[0]
          | .release = "6.12.113.2"
          | .identity.producer
            = "/nix/store/11111111111111111111111111111111-synthetic-producer-2"
          | .identity.module
            = "/nix/store/11111111111111111111111111111111-synthetic-producer-2/synthetic-2.ko"
          | .identity.moduleName = "synthetic_livepatch_2"
          | .identity.moduleSha256
            = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
          | .identity.inputDigest
            = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd")
      ]
    | .counts.plannedMembers = (.sets[0].members | length)
    | .counts.capturedMembers = (.sets[0].members | length)
  ' "$nfs_capture" >"$work/nfs-capture-two.json"

  printf 'NFS rendered one/two-member stack admission passed\n'

  nfs_row=$(jq -cer '[.rows[] | select(
      .scope == "fix"
      and .platformId == "amd"
      and .oracleIds == ["nfs-client-operation-safety"]
    )]
    | if length == 1 then .[0] else error("AMD NFS row is not unique") end' "$nfs_plan")
  nfs_row_id=$(jq -er '.rowId' <<<"$nfs_row")
  nfs_other_row_id=$(jq -er '.rows[] | select(
    .scope == "fix"
    and .platformId == "intel"
    and .oracleIds == ["nfs-client-operation-safety"]
  ) | .rowId' "$nfs_plan")
  nfs_two_row=$(jq -cer '[.rows[] | select(
      .scope == "fix"
      and .platformId == "amd"
      and .oracleIds == ["nfs-client-operation-safety"]
    )]
    | if length == 1 then .[0] else error("two-member AMD NFS row is not unique") end' \
    "$work/nfs-plan-two.json")
  nfs_two_row_id=$(jq -er '.rowId' <<<"$nfs_two_row")

  write_nfs_marker() {
    local plan_file=$1
    local capture_file=$2
    local selected_row=$3
    local output_file=$4
    jq -cn \
      --argjson row "$selected_row" \
      --slurpfile plan "$plan_file" \
      --slurpfile capture "$capture_file" '
      ($plan[0].sets[0].members | map(.release)) as $releases
      | {
        schemaVersion: 1,
        oracleId: "nfs-client-operation-safety",
        platformId: $row.platformId,
        runnerClass: $row.runnerClass,
        rowId: $row.rowId,
        setId: $row.setId,
        nativeRelease: $plan[0].sets[0].kernelVersion,
        tipRelease: $plan[0].sets[0].tipRelease,
        members: ($capture[0].sets[0].members | map({release, identity})),
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
        forward: ($releases | map({release: ., enabled: 1, transition: 0, replace: 0})),
        reverse: [
          range(($releases | length) - 1; -1; -1) as $index
          | {
              removedRelease: $releases[$index],
              release: (
                if $index == 0 then $plan[0].sets[0].kernelVersion
                else $releases[$index - 1]
                end
              ),
              moduleRemoved: true
            }
        ],
        kernelHealth: "clean"
      }
    ' >"$output_file"
  }

  write_nfs_marker "$nfs_plan" "$nfs_capture" "$nfs_row" "$work/nfs-marker.json"
  write_nfs_marker "$work/nfs-plan-two.json" "$work/nfs-capture-two.json" \
    "$nfs_two_row" "$work/nfs-marker-two.json"

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
  jq -e '
    .schemaVersion == 1
    and .accepted == true
    and .validator.status == "accepted"
    and .validator.members == ["6.12.113.1"]
    and .validator.tipRelease == "6.12.113.1"
  ' \
    "$work/nfs-valid/result.json" >/dev/null
  run_nfs_validator two-member "$work/nfs-plan-two.json" "$work/nfs-capture-two.json" \
    "$nfs_two_row_id" "$work/nfs-marker-two.json"
  jq -e '
    .schemaVersion == 1
    and .accepted == true
    and .validator.status == "accepted"
    and .validator.members == ["6.12.113.1", "6.12.113.2"]
    and .validator.tipRelease == "6.12.113.2"
  ' "$work/nfs-two-member/result.json" >/dev/null

  jq '.sets[0].members[0].kernelVersion = "6.12.114"' "$nfs_plan" >"$work/nfs-plan-target-mismatch.json"
  jq 'del(.sets[0].members[0].kernelVersion)' "$nfs_plan" >"$work/nfs-plan-target-missing.json"
  jq '.sets[0].members[0].release = "6.12.113.2"' "$nfs_capture" >"$work/nfs-capture-release-mismatch.json"
  jq '.sets[0].members |= reverse' \
    "$work/nfs-capture-two.json" >"$work/nfs-capture-two-reordered.json"
  jq 'del(.sets[0].members[1]) | .counts.capturedMembers = 1' \
    "$work/nfs-capture-two.json" >"$work/nfs-capture-two-missing.json"
  jq '
    .sets[0].members += [(.sets[0].members[1] | .release = "6.12.113.3")]
    | .counts.capturedMembers = 3
  ' "$work/nfs-capture-two.json" >"$work/nfs-capture-two-extra.json"
  jq '.members[0].identity.moduleSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "$work/nfs-marker.json" >"$work/nfs-marker-identity-mismatch.json"
  jq '.members |= reverse' \
    "$work/nfs-marker-two.json" >"$work/nfs-marker-two-reordered.json"
  jq '.tipRelease = "6.12.113.1"' \
    "$work/nfs-marker-two.json" >"$work/nfs-marker-two-tip-mismatch.json"
  jq '.reverse |= reverse' \
    "$work/nfs-marker-two.json" >"$work/nfs-marker-two-reverse-mismatch.json"
  jq '.platformId = "intel"' "$work/nfs-marker.json" >"$work/nfs-marker-wrong-platform.json"
  printf '{invalid-json\n' >"$work/nfs-marker-malformed.json"

  expect_nfs_refuse target-mismatch "$work/nfs-plan-target-mismatch.json" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse target-missing "$work/nfs-plan-target-missing.json" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse release-mismatch "$nfs_plan" "$work/nfs-capture-release-mismatch.json" \
    "$nfs_row_id" "$work/nfs-marker.json"
  expect_nfs_refuse two-reordered "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two-reordered.json" "$nfs_two_row_id" "$work/nfs-marker-two.json"
  expect_nfs_refuse two-missing "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two-missing.json" "$nfs_two_row_id" "$work/nfs-marker-two.json"
  expect_nfs_refuse two-extra "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two-extra.json" "$nfs_two_row_id" "$work/nfs-marker-two.json"
  expect_nfs_refuse identity-mismatch "$nfs_plan" "$nfs_capture" \
    "$nfs_row_id" "$work/nfs-marker-identity-mismatch.json"
  expect_nfs_refuse marker-two-reordered "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two.json" "$nfs_two_row_id" "$work/nfs-marker-two-reordered.json"
  expect_nfs_refuse marker-two-tip "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two.json" "$nfs_two_row_id" "$work/nfs-marker-two-tip-mismatch.json"
  expect_nfs_refuse marker-two-reverse "$work/nfs-plan-two.json" \
    "$work/nfs-capture-two.json" "$nfs_two_row_id" "$work/nfs-marker-two-reverse-mismatch.json"
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

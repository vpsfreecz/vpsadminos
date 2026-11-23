# Sourced by the lightweight qualification checks.
extract_method() {
  local begin=$1
  local end=$2
  local source=$3
  local output=$4

  [[ $(grep -F -c -- "$begin" "$source") -eq 1 ]]
  [[ $(grep -F -c -- "$end" "$source") -eq 1 ]]
  awk -v begin="$begin" -v end="$end" '
    index($0, begin) { capture = 1; next }
    index($0, end) { capture = 0 }
    capture { print }
  ' "$source" >"$output"
  [[ -s "$output" ]]
}


write_reverse_fixture() {
  cat <<'RUBY'
require 'fileutils'
require 'open3'
require 'pathname'
require 'shellwords'
require 'tmpdir'

class PredicateMachine
  attr_reader :events, :module_name, :module_path, :module_root, :patch_path

  def initialize(root, module_name)
    @root = Pathname(root)
    @module_name = module_name
    @patch_path = @root.join('patch')
    @module_root = @root.join('modules')
    @module_path = @module_root.join(module_name)
    @events = []
  end

  def configure(state)
    FileUtils.rm_rf(patch_path)
    FileUtils.rm_rf(module_root)
    FileUtils.mkdir_p(module_root)
    FileUtils.mkdir_p(module_path) unless state == :premature_module_loss

    case state
    when :positive, :premature_module_loss
      nil
    when :active
      write_patch_state('1', '0', '0')
    when :pending
      write_patch_state('0', '1', '0')
    when :disabled_extant
      write_patch_state('0', '0', '0')
    when :malformed
      write_patch_state('invalid', 'invalid', 'invalid')
    when :missing_files
      FileUtils.mkdir_p(patch_path)
    else
      raise "unsupported fixture state: #{state}"
    end
    events.clear
  end

  def succeeds(command, timeout: nil)
    raise 'unexpected succeeds timeout' unless [60, nil].include?(timeout)

    if command.include?('echo 0 >')
      raise 'disable write did not target the exact patch' unless command.include?(patch_path.to_s)
      raise 'disable write lost the module prematurely' unless module_path.directory?
      events << :disable
      FileUtils.rm_rf(patch_path)
    elsif command.start_with?('rmmod ')
      raise 'rmmod ran before completed-disable convergence' unless !patch_path.exist? && module_path.directory?
      events << :rmmod
      FileUtils.rm_rf(module_path)
    elsif command.include?('uname -r')
      raise 'release check ran before full removal' if patch_path.exist? || module_path.exist?
      events << :release
    else
      raise "unexpected succeeds command: #{command}"
    end
    ['', '']
  end

  def wait_until_succeeds(command, timeout:)
    raise 'unexpected wait timeout' unless timeout == 180
    event =
      if command.include?('test -d /sys/module/')
        :completed_disable_wait
      elsif command.include?('test ! -d /sys/module/')
        :removed_wait
      else
        raise "unexpected wait command: #{command}"
      end
    events << event
    translated = command.gsub('/sys/module/', "#{module_root}/")
    _stdout, stderr, status = Open3.capture3(ENV.fetch('F9_TEST_BASH'), '-c', translated)
    raise "wait predicate refused: #{stderr}" unless status.success?
    ['', '']
  end

  private

  def write_patch_state(enabled, transition, replace)
    FileUtils.mkdir_p(patch_path)
    {
      'enabled' => enabled,
      'transition' => transition,
      'replace' => replace,
    }.each do |name, value|
      patch_path.join(name).write("#{value}\n")
    end
  end
end

def check_completed_disable(machine, label)
  machine.configure(:positive)
  yield

  %i[active pending disabled_extant malformed missing_files premature_module_loss].each do |state|
    machine.configure(state)
    refused = false
    begin
      yield
    rescue RuntimeError
      refused = true
    end
    raise "#{label} unexpectedly accepted #{state}" unless refused
  end
end
RUBY
}

check_generic_reverse() {
  extract_method F9_GENERIC_COMPLETED_DISABLE_BEGIN F9_GENERIC_COMPLETED_DISABLE_END \
    "$generic_template" "$work/generic-completed-disable.rb"
  extract_method F9_GENERIC_REMOVAL_WAIT_BEGIN F9_GENERIC_REMOVAL_WAIT_END \
    "$generic_template" "$work/generic-removal-wait.rb"
  extract_method F9_GENERIC_REVERSE_SET_BEGIN F9_GENERIC_REVERSE_SET_END \
    "$generic_template" "$work/generic-reverse-set.rb"

  {
    write_reverse_fixture
    cat <<'RUBY'
class GenericConsumer
  def initialize(machine)
    @machine = machine
    @set = {'kernelVersion' => '6.12.113'}
    @captured_set = {
      'members' => [{
        'release' => '6.12.113.1',
        'identity' => {'moduleName' => machine.module_name},
      }],
    }
  end

  def machine
    @machine
  end

  def patch_dir(_module_name)
    machine.patch_path.to_s
  end

  def shell(value)
    Shellwords.escape(value)
  end
RUBY
    cat "$work/generic-completed-disable.rb"
    cat "$work/generic-removal-wait.rb"
    cat "$work/generic-reverse-set.rb"
      cat <<'RUBY'
end

Dir.mktmpdir('livepatch-reverse-convergence-') do |root|
  module_name = 'lp_612113_1_test'
  machine = PredicateMachine.new(root, module_name)
  generic = GenericConsumer.new(machine)
  check_completed_disable(machine, 'generic') { generic.wait_completed_disable(module_name) }
  machine.configure(:active)
  observations = generic.reverse_set
  expected_events = %i[disable completed_disable_wait rmmod removed_wait release]
  raise "generic reverse order mismatch: #{machine.events.inspect}" unless machine.events == expected_events
  expected_observations = [{removedRelease: '6.12.113.1', release: '6.12.113'}]
  raise "generic reverse observation mismatch" unless observations == expected_observations
end
puts 'generic completed-disable convergence matrix passed'
RUBY
  } >"$work/generic-reverse-convergence.rb"
  F9_TEST_BASH=$BASH "$ruby" -c "$work/generic-reverse-convergence.rb" >/dev/null
  F9_TEST_BASH=$BASH "$ruby" "$work/generic-reverse-convergence.rb"
}

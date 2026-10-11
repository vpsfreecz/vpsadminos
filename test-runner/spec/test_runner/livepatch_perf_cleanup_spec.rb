# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'shellwords'

RSpec.describe TestRunner::TestEvaluator do
  let(:machine) { instance_double(OsVm::Machine) }

  let(:context) do
    klass = Class.new do
      class << self
        attr_accessor :machine, :cleanup

        def after(type, &block)
          raise 'unexpected hook' unless type == :suite

          self.cleanup = block
        end
      end
    end
    klass.machine = machine
    klass.const_set(:CORRECTED_NAME, 'livepatch_7')
    klass.const_set(:PATCH_DIR, '/sys/kernel/livepatch/livepatch_7')
    source = File.join(REPO_ROOT, 'tests/suite/kernel/livepatch-perf-v7.nix')
    hook = File.read(source)[/      after\(:suite\) do\n.*?^      end/m]
    raise 'missing perf teardown' unless hook

    klass.class_eval(hook, source)
    klass
  end

  def cleanup_command
    captured = nil
    allow(machine).to receive(:succeeds) do |command, timeout:|
      expect(timeout).to eq(120)
      captured = command
      [0, '']
    end
    context.cleanup.call
    expect(captured).not_to be_nil
    captured
  end

  [
    ['an enabled patch', '1', true],
    ['an already disabled patch', '0', true],
    ['a deferred module reference without a patch object', nil, true],
    ['an already absent module', nil, false]
  ].each do |description, enabled, loaded|
    it "completes cleanup for #{description}" do
      with_tmpdir do |directory|
        patch_dir = File.join(directory, 'sys/kernel/livepatch/livepatch_7')
        module_dir = File.join(directory, 'sys/module/livepatch_7')
        FileUtils.mkdir_p(module_dir) if loaded
        if enabled
          FileUtils.mkdir_p(patch_dir)
          File.write(File.join(patch_dir, 'enabled'), enabled)
          File.write(File.join(patch_dir, 'transition'), '0')
        end

        # Exercise the real fixture command against bounded temporary sysfs
        # stand-ins. The transition is pending on its first read, and the
        # first removal retains a reference even after transition completion.
        shell = <<~SH
          set -euo pipefail
          patch_dir=#{Shellwords.escape(patch_dir)}
          module_dir=#{Shellwords.escape(module_dir)}
          state_dir=#{Shellwords.escape(directory)}
          cat() {
            if test "$1" = "$patch_dir/transition"; then
              if test ! -e "$state_dir/transition-seen"; then
                touch "$state_dir/transition-seen"
                printf '1\n'
                return
              fi
              touch "$state_dir/transition-complete"
            fi
            command cat "$@"
          }
          rmmod() {
            test "$1" = livepatch_7 || return 90
            if test -d "$patch_dir"; then
              test "$(command cat "$patch_dir/enabled")" = 0 || return 91
              test -e "$state_dir/transition-complete" || return 92
            fi
            if test ! -e "$state_dir/removal-attempt"; then
              touch "$state_dir/removal-attempt"
              printf 'reference still held\n' >&2
              return 1
            fi
            rmdir "$module_dir"
          }
          #{cleanup_command.gsub('/sys/', "#{Shellwords.escape(directory)}/sys/")}
        SH
        stdout, stderr, status = Open3.capture3('timeout', '3', 'bash', '-c', shell)
        expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
        expect(File.directory?(module_dir)).to be(false)
        expect(File.exist?(File.join(directory, 'removal-attempt'))).to eq(loaded)
        next unless enabled

        expect(File.read(File.join(patch_dir, 'enabled')).strip).to eq('0')
        expect(File.exist?(File.join(directory, 'transition-complete'))).to be(true)
      end
    end
  end

  it 'does not suppress failed teardown commands' do
    error = RuntimeError.new('rollback or removal failed')
    allow(machine).to receive(:succeeds).and_raise(error)

    expect { context.cleanup.call }.to raise_error(error)
  end
end

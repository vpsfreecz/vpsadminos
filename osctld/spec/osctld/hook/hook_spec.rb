# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/hook'
require 'osctld/hook/base'
require 'osctld/hook/manager'
require 'osctld/hook/script'

RSpec.describe OsCtld::Hook do
  let(:event_class) do
    Class.new do
      attr_reader :user_hook_script_dir

      def initialize(user_hook_script_dir)
        @user_hook_script_dir = user_hook_script_dir
      end
    end
  end

  let(:blocking_hook_class) do
    klass = Class.new(OsCtld::Hook::Base)
    klass.hook(event_class, :blocking_event, klass)
    klass.blocking(true)
    klass
  end

  let(:async_hook_class) do
    klass = Class.new(OsCtld::Hook::Base)
    klass.hook(event_class, :async_event, klass)
    klass.blocking(false)
    klass
  end

  before do
    OsCtl::Lib::Logger.setup(:none)
  end

  it 'registers hooks and reports them by event class' do
    blocking_hook_class

    expect(described_class.hooks(event_class)).to include(blocking_event: blocking_hook_class)
    expect(described_class.exist?(event_class, :blocking_event)).to be(true)
  end

  it 'executes blocking hooks and raises on non-zero exit status' do
    with_tmpdir do |dir|
      event = event_class.new(dir)
      hook = blocking_hook_class.new(event, {})

      ok = write_executable(File.join(dir, 'ok'))
      fail_script = write_executable(File.join(dir, 'fail'), "#!/bin/sh\nexit 7\n")

      expect(hook.exec(ok)).to be(true)
      expect { hook.exec(fail_script) }.to raise_error(OsCtld::HookFailed, /exited with 7/)
    end
  end

  it 'dispatches async hooks through Hook.watch' do
    with_tmpdir do |dir|
      event = event_class.new(dir)
      hook = async_hook_class.new(event, {})
      script = write_executable(File.join(dir, 'async'))

      allow(described_class).to receive(:watch).and_return(:thread)
      allow(Process).to receive(:fork).and_return(1234)

      expect(hook.exec(script)).to eq(:thread)
      expect(described_class).to have_received(:watch).with(hook, script, kind_of(Integer))
    end
  end

  it 'lists singleton and hook.d scripts sorted by basename and executable status' do
    with_tmpdir do |dir|
      event = event_class.new(dir)
      singleton = write_executable(File.join(dir, 'blocking-event'))
      FileUtils.mkdir_p(File.join(dir, 'blocking-event.d'))
      write_executable(File.join(dir, 'blocking-event.d', '20-second'))
      write_executable(File.join(dir, 'blocking-event.d', '10-first'))
      File.write(File.join(dir, 'blocking-event.d', '99-ignore'), '')

      scripts = OsCtld::Hook::Manager.new(event).list_scripts(blocking_hook_class)

      expect(scripts.map(&:abs_path)).to include(singleton)
      expect(scripts.map(&:rel_path)).to eq([
                                              'blocking-event.d/10-first',
                                              'blocking-event.d/20-second',
                                              'blocking-event'
                                            ])
    end
  end

  it 'lists all scripts for all registered hook types and runs them through the manager' do
    with_tmpdir do |dir|
      event = event_class.new(dir)
      blocking_hook_class
      async_hook_class
      write_executable(File.join(dir, 'blocking-event'))
      write_executable(File.join(dir, 'async-event'))

      manager = OsCtld::Hook::Manager.new(event)

      expect(manager.list_all_scripts.map(&:name)).to contain_exactly(:blocking_event, :async_event)

      hook_instance = instance_double(blocking_hook_class, exec: nil)
      allow(blocking_hook_class).to receive(:new).and_return(hook_instance)

      manager.run(blocking_hook_class, {})

      expect(hook_instance).to have_received(:exec).with(File.join(dir, 'blocking-event'))
    end
  end
end

# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/hook'
require 'osctld/hook/base'
require 'osctld/hook/manager'
require 'osctld/hook/script'
require 'osctld/container/lifecycle'

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

  it 'terminates the complete process group of a timed out blocking hook' do
    with_tmpdir do |dir|
      event = event_class.new(dir)
      hook = blocking_hook_class.new(event, timeout: 0.1)
      child_pid_file = File.join(dir, 'child.pid')
      script = write_executable(
        File.join(dir, 'timeout'),
        <<~SH
          #!/bin/sh
          trap 'exit 0' TERM
          sh -c 'trap "" TERM; while :; do sleep 1; done' &
          echo $! > #{child_pid_file}
          wait
        SH
      )

      expect { hook.exec(script) }.to raise_error(
        OsCtld::HookFailed,
        /exited with 124/
      )

      child_pid = Integer(File.read(child_pid_file))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      while process_running?(child_pid) \
          && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep(0.05)
      end

      expect(process_running?(child_pid)).to be(false)
    ensure
      Process.kill('KILL', child_pid) if child_pid && process_running?(child_pid)
    end
  rescue Errno::ESRCH
    nil
  end

  it 'dispatches async hooks through Hook.watch' do
    with_tmpdir do |dir|
      event = event_class.new(dir)
      hook = async_hook_class.new(event, {})
      script = write_executable(File.join(dir, 'async'))

      allow(described_class).to receive(:watch).and_return(:thread)
      allow(Process).to receive(:fork).and_return(1234)

      expect(hook.exec(script)).to eq(:thread)
      expect(described_class).to have_received(:watch).with(
        hook,
        script,
        kind_of(Integer),
        lifecycle_owner: nil
      )
    end
  end

  it 'contains lifecycle completion errors in async hook watchers' do
    status = instance_double(Process::Status, exitstatus: 0)
    hook_class = Class.new do
      def self.hook_name = :async_event

      def event_instance = @event_instance ||= Object.new

      def finish_lifecycle_process(_owner); end
    end
    hook = hook_class.new
    allow(Process).to receive(:wait2).with(1234).and_return([1234, status])
    allow(hook).to receive(:finish_lifecycle_process)
      .with({ run_id: 'run-1' })
      .and_raise('lifecycle completion failed')

    thread = described_class.watch(
      hook,
      '/hooks/async-event',
      1234,
      lifecycle_owner: { run_id: 'run-1' }
    )

    expect { thread.value }.not_to raise_error
    expect(hook).to have_received(:finish_lifecycle_process).once
  end

  it 'records a generation hook child before releasing it to exec' do
    with_tmpdir do |dir|
      lifecycle = instance_double(
        OsCtld::Container::Lifecycle,
        run: {
          'resources' => {
            'host_effects' => '/osctl/test/run-1/host-effects'
          }
        },
        register_process: 'process-1',
        finish_process: false
      )
      run_conf = Struct.new(:run_id).new('run-1')
      owned_event_class = Class.new do
        attr_reader :user_hook_script_dir, :lifecycle, :run_conf

        def initialize(user_hook_script_dir, lifecycle, run_conf)
          @user_hook_script_dir = user_hook_script_dir
          @lifecycle = lifecycle
          @run_conf = run_conf
        end

        def get_past_run_conf
          nil
        end
      end
      owned_hook_class = Class.new(OsCtld::Hook::Base)
      owned_hook_class.hook(owned_event_class, :owned_event, owned_hook_class)
      owned_hook_class.blocking(true)
      event = owned_event_class.new(dir, lifecycle, run_conf)
      hook = owned_hook_class.new(event, {})
      script = write_executable(File.join(dir, 'owned'))
      allow(OsCtld::CGroup).to receive(:mkpath_all)
      allow(OsCtld::CGroup).to receive(:attach_to_all)

      expect(hook.exec(script)).to be(true)
      expect(OsCtld::CGroup).to have_received(:attach_to_all).with(
        ['', 'osctl', 'test', 'run-1', 'host-effects'],
        pid: kind_of(Integer)
      )
      expect(lifecycle).to have_received(:register_process).with(
        'run-1',
        kind: 'hook:owned_event',
        pid: kind_of(Integer)
      )
      expect(lifecycle).to have_received(:finish_process).with(
        'run-1',
        'process-1'
      )
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

  def process_running?(pid)
    state = File.read("/proc/#{pid}/stat").split[2]
    state != 'Z'
  rescue Errno::ENOENT
    false
  end
end

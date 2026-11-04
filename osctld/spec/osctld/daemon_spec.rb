# frozen_string_literal: true

require 'osctld/daemon'
require 'osctld/command'
require 'osctld/eventd'
require 'osctld/thread_reaper'

RSpec.describe OsCtld::Daemon do
  before do
    described_class.class_variable_set(:@@instance, nil)
  end

  after do
    described_class.class_variable_set(:@@instance, nil)
  end

  describe '.create' do
    it 'rejects duplicate creation and keeps the original instance' do
      daemon = instance_double(described_class)

      allow(described_class).to receive(:new).with('daemon.yml').and_return(daemon)

      expect(described_class.create('daemon.yml')).to be(daemon)
      expect(described_class.get).to be(daemon)
      expect { described_class.create('daemon.yml') }.to raise_error(
        RuntimeError,
        'Daemon already instantiated'
      )
      expect(described_class.get).to be(daemon)
      expect(described_class).to have_received(:new).once
    end
  end

  describe '#run_shutdown' do
    let(:daemon) do
      described_class.allocate.tap do |d|
        d.instance_variable_set(:@shutdown_mutex, Mutex.new)
        d.instance_variable_set(:@shutdown_cv, ConditionVariable.new)
      end
    end
    let(:operation_threads) { [] }
    let(:operation_gates) { [] }
    let(:joined) { Queue.new }
    let(:marker_dir) { Dir.mktmpdir('daemon-shutdown-spec-') }

    def marker = OsCtld::RunState::SHUTDOWN_MARKER

    def operation_gate
      Queue.new.tap { |gate| operation_gates << gate }
    end

    def start_operation(&block)
      result = Queue.new
      thread = Thread.new do
        result << daemon.run_shutdown(&block)
      rescue Exception => e # rubocop:disable Lint/RescueException -- Preserve interruption and cleanup outcomes.
        result << e
      end
      operation_threads << thread
      [result, thread]
    end

    def nonlocal_shutdown_exit
      daemon.run_shutdown { return :not_completed }
    end

    before do
      stub_const('OsCtld::RunState::SHUTDOWN_MARKER', File.join(marker_dir, 'shutdown'))
      # osctld runs as root and can reopen its mode-000 marker. Emulate only
      # that privilege for this temporary fixture, preserving the mode tested.
      allow(File).to receive(:new).and_wrap_original do |method, path, *args|
        if path == OsCtld::RunState::SHUTDOWN_MARKER && File.exist?(path)
          mode = File.stat(path).mode & 0o777
          File.chmod(mode | 0o200, path)
        end
        begin
          method.call(path, *args)
        ensure
          File.chmod(mode, path) if mode
        end
      end
      allow(daemon.instance_variable_get(:@shutdown_cv)).to receive(:wait).and_wrap_original do |method, mutex|
        joined << :waiting
        method.call(mutex)
      end
    end

    after do
      daemon.abort_shutdown if operation_threads.any?(&:alive?)
      operation_gates.each { |gate| gate << :release }
      joined_threads = operation_threads.map { |thread| !thread.join(5).nil? }
      FileUtils.remove_entry(marker_dir)
      raise 'daemon operation fixture left a thread alive' unless joined_threads.all?
    end

    it 'preserves pending and confirmed marker modes and resumes from either after restart' do
      expect(daemon.shutdown?).to be(false)
      daemon.begin_shutdown
      expect(daemon.shutdown?).to be(true)
      expect(File.stat(marker).mode & 0o777).to eq(0)
      restarted = described_class.allocate
      restarted.instance_variable_set(:@shutdown_mutex, Mutex.new)
      restarted.instance_variable_set(:@shutdown_cv, ConditionVariable.new)
      expect(restarted.run_shutdown { :empty_pool_success }).to eq(:empty_pool_success)
      expect(File.stat(marker).mode & 0o777).to eq(0o100)
      expect(daemon.run_shutdown { :resumed_confirmed }).to eq(:resumed_confirmed)
      daemon.abort_shutdown
      expect(daemon.shutdown?).to be(false)
      expect { daemon.confirm_shutdown }.to raise_error(OsCtld::CommandFailed, 'shutdown aborted')
      expect(daemon.shutdown?).to be(false)
      expect(daemon.run_shutdown { :fresh_request }).to eq(:fresh_request)
      expect(daemon.abort_shutdown?).to be(false)
      expect(File.stat(marker).mode & 0o777).to eq(0o100)
    end

    it 'publishes a failure to create the pending marker and permits a later request' do
      error = IOError.new('marker fixture failure')
      allow(File).to receive(:new).and_call_original
      allow(File).to receive(:new).with(marker, 'w', 0o000).and_raise(error)
      expect { daemon.run_shutdown { raise 'must not execute' } }.to(raise_error { |e| expect(e).to equal(error) })
      allow(File).to receive(:new).with(marker, 'w', 0o000).and_call_original
      expect(daemon.run_shutdown { :later }).to eq(:later)
    end

    it 'shares a confirmation error and retains pending restart intent' do
      entered = Queue.new
      release = operation_gate
      error = IOError.new('confirmation fixture failure')
      allow(File).to receive(:chmod).with(0o100, marker).and_raise(error)
      owner_result, = start_operation do
        entered << :running
        pop_with_timeout(release, timeout: 5)
        :success
      end
      pop_with_timeout(entered, timeout: 5)
      joined_result, = start_operation { raise 'duplicate must not execute' }
      pop_with_timeout(joined, timeout: 5)
      release << :finish
      expect(pop_with_timeout(owner_result, timeout: 5)).to equal(error)
      expect(pop_with_timeout(joined_result, timeout: 5)).to equal(error)
      expect(File.stat(marker).mode & 0o777).to eq(0)
    end

    [false, true].each do |failed|
      it "retains a captured outcome across a later operation, failed #{failed}" do
        entered = Queue.new
        finish_owner = operation_gate
        waiter_paused = Queue.new
        resume_waiter = operation_gate
        first_error = RuntimeError.new('first operation fixture failure')
        first_result = Object.new
        cv = daemon.instance_variable_get(:@shutdown_cv)
        allow(cv).to receive(:wait).and_wrap_original do |method, mutex|
          joined << :waiting
          method.call(mutex)
          # Delay a real awakened waiter while letting a subsequent request
          # acquire the guard. Return with the CV's normal mutex ownership.
          mutex.unlock
          begin
            waiter_paused << :paused
            pop_with_timeout(resume_waiter, timeout: 5)
          ensure
            mutex.lock
          end
        end
        owner_result, = start_operation do
          entered << :running
          pop_with_timeout(finish_owner, timeout: 5)
          raise first_error if failed

          first_result
        end
        pop_with_timeout(entered, timeout: 5)
        joined_result, = start_operation { raise 'duplicate must not execute' }
        pop_with_timeout(joined, timeout: 5)
        finish_owner << :finish
        expected = failed ? first_error : first_result
        expect(pop_with_timeout(owner_result, timeout: 5)).to equal(expected)
        pop_with_timeout(waiter_paused, timeout: 5)
        expect(daemon.run_shutdown { :new_result }).to eq(:new_result)
        resume_waiter << :wake
        expect(pop_with_timeout(joined_result, timeout: 5)).to equal(expected)
      end
    end

    it 'orders completion before an abort waiting on the confirmation guard' do
      entered = Queue.new
      finish_owner = operation_gate
      confirming = Queue.new
      finish_confirmation = operation_gate
      abort_entered = Queue.new
      aborted = Queue.new
      allow(File).to receive(:chmod).with(0o100, marker).and_wrap_original do |method, *args|
        confirming << :confirming
        pop_with_timeout(finish_confirmation, timeout: 5)
        method.call(*args)
      end
      owner_result, = start_operation do
        entered << :running
        pop_with_timeout(finish_owner, timeout: 5)
        :success
      end
      pop_with_timeout(entered, timeout: 5)
      joined_result, = start_operation { raise 'duplicate must not execute' }
      pop_with_timeout(joined, timeout: 5)
      finish_owner << :finish
      pop_with_timeout(confirming, timeout: 5)
      operation_threads << Thread.new do
        abort_entered << :attempting
        daemon.abort_shutdown
        aborted << :done
      end
      pop_with_timeout(abort_entered, timeout: 5)
      expect(aborted).to be_empty
      finish_confirmation << :finish
      expect(pop_with_timeout(owner_result, timeout: 5)).to eq(:success)
      expect(pop_with_timeout(joined_result, timeout: 5)).to eq(:success)
      expect(pop_with_timeout(aborted, timeout: 5)).to eq(:done)
      expect(daemon.shutdown?).to be(false)
    end

    it 'wakes joiners with the original interruption and releases admission' do
      entered = Queue.new
      release = operation_gate
      error = Interrupt.new('owner fixture interruption')
      owner_result, owner_thread = start_operation do
        entered << :running
        pop_with_timeout(release, timeout: 5)
      end
      pop_with_timeout(entered, timeout: 5)
      joined_result, = start_operation { raise 'duplicate must not execute' }
      pop_with_timeout(joined, timeout: 5)
      owner_thread.raise(error)
      expect(pop_with_timeout(owner_result, timeout: 5)).to equal(error)
      expect(pop_with_timeout(joined_result, timeout: 5)).to equal(error)
      expect(File.stat(marker).mode & 0o777).to eq(0)
      expect(daemon.run_shutdown { :later }).to eq(:later)
    end

    it 'does not publish a nonlocal owner exit as success or strand admission' do
      expect { nonlocal_shutdown_exit }.to raise_error(OsCtld::CommandFailed, 'shutdown aborted')
      expect(File.stat(marker).mode & 0o777).to eq(0)
      expect(daemon.run_shutdown { :later }).to eq(:later)
    end
  end

  describe '#stop' do
    it 'drains client threads before shutting down command dependencies' do
      daemon = described_class.allocate
      server_class = Class.new do
        def stop; end
      end
      repo_class = Class.new do
        def stop; end
      end
      pool_class = Class.new do
        def stop; end
      end
      server = instance_spy(server_class)
      server_thread = instance_double(Thread, join: nil)
      repo = instance_spy(repo_class)
      pool = instance_spy(pool_class)

      stub_const('OsCtld::UserControl', Class.new do
        def self.stop; end
      end)
      stub_const('OsCtld::SendReceive', Class.new do
        def self.stop; end
      end)
      stub_const('OsCtld::DB::Repositories', Class.new do
        def self.each; end
      end)
      stub_const('OsCtld::DB::Pools', Class.new do
        def self.get; end
      end)
      stub_const('OsCtld::CpuScheduler', Class.new do
        def self.shutdown; end
      end)
      stub_const('OsCtld::Monitor', Module.new)
      stub_const('OsCtld::Monitor::Master', Class.new do
        def self.stop; end
      end)

      daemon.instance_variable_set(:@server, server)
      daemon.instance_variable_set(:@server_thread, server_thread)
      allow(daemon).to receive(:log)
      allow(daemon).to receive(:exit!).and_raise(SystemExit)
      allow(FileUtils).to receive(:rm_f)
      allow(OsCtld::UserControl).to receive(:stop)
      allow(OsCtld::SendReceive).to receive(:stop)
      allow(OsCtld::DB::Repositories).to receive(:each).and_yield(repo)
      allow(OsCtld::DB::Pools).to receive(:get).and_return([pool])
      allow(OsCtld::Hook).to receive(:run)
      allow(OsCtld::ThreadReaper).to receive(:drain)
      allow(OsCtld::ThreadReaper).to receive(:stop)
      allow(OsCtld::Eventd).to receive(:shutdown)
      allow(OsCtld::CpuScheduler).to receive(:shutdown)
      allow(OsCtld::Monitor::Master).to receive(:stop)
      allow(OsCtld::LockRegistry).to receive(:stop)

      expect { daemon.stop }.to raise_error(SystemExit)

      expect(OsCtld::Hook).to have_received(:run).with(daemon, :pre_stop).ordered
      expect(server).to have_received(:stop).ordered
      expect(server_thread).to have_received(:join).ordered
      expect(OsCtld::ThreadReaper).to have_received(:drain).with(group: :management).ordered
      expect(OsCtld::UserControl).to have_received(:stop).ordered
      expect(OsCtld::ThreadReaper).to have_received(:stop).ordered
      expect(OsCtld::Eventd).to have_received(:shutdown).ordered
      expect(OsCtld::SendReceive).to have_received(:stop).ordered
      expect(repo).to have_received(:stop).ordered
      expect(pool).to have_received(:stop).ordered
      expect(OsCtld::CpuScheduler).to have_received(:shutdown).ordered
      expect(OsCtld::Monitor::Master).to have_received(:stop).ordered
    end

    it 'logs daemon pre-stop hook failures and continues stopping' do
      daemon = described_class.allocate
      hook_class = Class.new do
        def self.hook_name
          :pre_stop
        end
      end

      allow(OsCtld::Hook).to receive(:run).and_raise(OsCtld::HookFailed.new(
                                                       hook_class.new,
                                                       '/run/osctl/hooks/daemon/pre-stop',
                                                       1
                                                     ))
      allow(daemon).to receive(:log)

      expect(daemon.send(:run_pre_stop_hooks)).to be_nil
      expect(daemon).to have_received(:log).with(
        :warn,
        include('Daemon pre-stop hook failed')
      )
    end

    it 'exposes the daemon lifecycle hook directory' do
      daemon = described_class.allocate

      expect(daemon.user_hook_script_dir).to eq(OsCtld::RunState::DAEMON_HOOK_DIR)
    end

    it 'builds daemon pre-stop hook environments' do
      hook = described_class::Hooks::PreStop.new(described_class.allocate, {})

      expect(hook.send(:environment)).to include(
        'OSCTL_HOOK_NAME' => 'pre-stop',
        'OSCTL_DAEMON_STATE' => 'stopping',
        'OSCTL_DAEMON_PID' => Process.pid.to_s
      )
    end
  end

  describe OsCtld::Daemon::ClientHandler do
    before do
      allow(OsCtld::Eventd).to receive(:report)
    end

    it 'requests the active command to stop without closing the client socket' do
      with_socket_pair do |server_sock, _client_sock|
        handler = described_class.new(server_sock, {})
        cmd_class = Class.new do
          def request_stop; end
        end
        cmd = instance_double(cmd_class, request_stop: nil)

        handler.instance_variable_set(:@cmd, cmd)

        handler.request_stop

        expect(cmd).to have_received(:request_stop).once
        expect(server_sock).not_to be_closed
      end
    end

    it 'does not retain completed commands as active' do
      with_socket_pair do |server_sock, _client_sock|
        handler = described_class.new(server_sock, {})
        cmd_class = Class.new do
          def initialize(_opts, id:, handler:); end

          def base_execute; end

          def request_stop; end
        end
        cmd = instance_double(
          cmd_class,
          base_execute: { status: true, output: 'done' },
          request_stop: nil
        )

        allow(OsCtld::Command).to receive(:find).with(:ping).and_return(cmd_class)
        allow(OsCtld::Command).to receive(:get_id).and_return(42)
        allow(cmd_class).to receive(:new)
          .with({}, id: 42, handler:)
          .and_return(cmd)

        expect(handler.handle_cmd(cmd: 'ping', opts: {})).to eq(
          status: true,
          output: 'done'
        )

        handler.request_stop

        expect(cmd).not_to have_received(:request_stop)
      end
    end
  end
end

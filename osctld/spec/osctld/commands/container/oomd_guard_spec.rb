# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/manipulable'
require 'osctld/command'
require 'osctld/utils/container'
require 'osctld/utils/switch_user'
require 'osctld/commands/container/oomd_stop'
require 'osctld/commands/container/oomd_restart'
require 'osctld/daemon'
require 'osctld/eventd'
require 'osctld/hook'
require 'osctld/dist_config'
require 'osctld/process_identity'
require 'osctld/container/run_configuration'

RSpec.describe OsCtld::Commands::Container::OomdGuard do
  let(:lease) do
    identity = instance_double(OsCtld::ProcessIdentity, pid: 42, alive?: true,
                                                        read_proc_file: "42 (init) S #{(['0'] * 18).join(' ')} 123")
    instance_double(OsCtld::Container::RunConfiguration::InitLease, identity:, close: nil)
  end
  let(:run_conf) { instance_double(OsCtld::Container::RunConfiguration, acquire_init_lease: lease) }
  let(:ct) { OomdGuardHelpers::GuardContainer.new(run_conf) }
  let(:options) { { expected_init_pid: 42, expected_init_start_time: 123 } }
  let(:command) { OsCtld::Commands::Container::OomdStop.new(options, id: 1) }

  it 'checks the run only after waiting for the actual manipulation lock' do
    ct.acquire_manipulation_lock(command)
    waiting = Queue.new
    allow(ct).to receive(:manipulate).and_wrap_original do |method, *args, **kwargs, &block|
      waiting << true
      method.call(*args, **kwargs, &block)
    end
    options[:manipulation_lock] = 'wait'
    result = Queue.new
    worker = Thread.new do
      command.send(:with_oomd_run, ct) { result << :mutated }
    rescue OsCtld::CommandFailed => e
      result << e.message
    end
    pop_with_timeout(waiting, timeout: 2)
    expect(run_conf).not_to have_received(:acquire_init_lease)
    ct.init_pid = 43
    ct.release_manipulation_lock
    expect(pop_with_timeout(result, timeout: 2)).to include('no longer current')
    expect(worker.join(2)).to eq(worker)
  ensure
    ct.release_manipulation_lock if ct.manipulated_by == command
  end

  it 'does not honor the manual ignore-lock option' do
    ct.acquire_manipulation_lock(command)
    options[:manipulation_lock] = 'ignore'
    worker = Thread.new do
      command.send(:with_oomd_run, ct) { raise 'must not mutate' }
    rescue OsCtld::ResourceLocked
      :locked
    end
    expect(worker.value).to eq(:locked)
    expect(run_conf).not_to have_received(:acquire_init_lease)
  ensure
    ct.release_manipulation_lock
  end

  it 'closes the identity lease before re-entering the lifecycle lock and retains the outer lock' do
    command.send(:with_oomd_run, ct) do
      expect(lease).to have_received(:close)
      ct.manipulate(command) { expect(ct.manipulated_by).to eq(command) }
      expect(ct.manipulated_by).to eq(command)
    end
    expect(ct.is_being_manipulated?).to be(false)
  end

  it 'checks raw start ticks through the real pinned identity without holding its lease into stop' do
    current_identity = OsCtld::ProcessIdentity.new(Process.pid)
    current_lease = Struct.new(:identity) do
      def close = identity.close
    end.new(current_identity)
    allow(run_conf).to receive(:acquire_init_lease).and_return(current_lease)
    ct.init_pid = Process.pid
    options[:expected_init_pid] = Process.pid
    options[:expected_init_start_time] = Integer(File.read('/proc/self/stat').rpartition(') ').last.split.fetch(19))
    expect(command.send(:with_oomd_run, ct) { :accepted }).to eq(:accepted)
    expect(current_identity.pidfd).to be_nil
  ensure
    current_identity&.close
  end

  it 'rejects PID reuse with different start ticks without effects' do
    options[:expected_init_start_time] = 124
    expect { command.send(:with_oomd_run, ct) { raise 'mutated' } }.to raise_error(OsCtld::CommandFailed)
    expect(lease).to have_received(:close)
  end

  [nil, '42', 0, -1, 1.5].each do |bad|
    %i[expected_init_pid expected_init_start_time].each do |field|
      it "rejects #{field}=#{bad.inspect} before locking or effects" do
        options[field] = bad
        allow(ct).to receive(:manipulate).and_call_original
        expect { command.execute(ct) }.to raise_error(OsCtld::CommandFailed, /positive integer/)
        expect(ct).not_to have_received(:manipulate)
      end
    end
  end

  it 'runs existing stop and restart bodies under the same lock without a nested deadlock' do
    plan = instance_double(OomdGuardHelpers::GuardPlan, stop_ct: nil)
    ct.pool = Struct.new(:name, :autostart_plan).new('tank', plan)
    allow(OsCtld::Hook).to receive(:run)
    allow(OsCtld::DistConfig).to receive(:run) do |_rc, action, **args|
      expect(action).to eq(:stop)
      expect(args[:mode]).to eq(:kill)
      expect(ct.manipulated_by).not_to be_nil
      expect(lease).to have_received(:close)
    end
    restart = OsCtld::Commands::Container::OomdRestart.new(options.merge(reboot: true, stop_timeout: 60), id: 2)
    allow(restart).to receive(:call_cmd!) do |klass, **args|
      expect(ct.manipulated_by).to eq(restart)
      if klass == OsCtld::Commands::Container::Stop
        stop = klass.new(args, id: 3, indirect: true)
        allow(stop).to receive(:remove_accounting_cgroups)
        stop.execute(ct)
      else
        expect(args[:force]).to be(true)
        { status: true }
      end
    end
    stub_const('OsCtld::Commands::Container::Start', Class.new)
    expect(restart.execute(ct)).to eq(status: true)
    expect(plan).to have_received(:stop_ct).with(ct).once
    expect(ct.is_being_manipulated?).to be(false)
  end

  %i[ct_oomd_stop ct_oomd_restart].each do |name|
    it "rejects #{name} when the action connection reaches an old daemon" do
      # Model the old registry at the actual supported daemon dispatch boundary,
      # including replacement after a successful earlier preflight connection.
      expect(OsCtld::Command.find(name)).not_to be_nil
      preflight_class = Class.new do
        def initialize(_opts, **); end

        def base_execute = { status: true, output: { oomd_guard: true } }
      end
      allow(OsCtld::Command).to receive(:find).with(:ct_show).and_return(preflight_class)
      allow(OsCtld::Eventd).to receive(:report)
      preflight = OsCtld::Daemon::ClientHandler.new(nil, {})
      expect(preflight.handle_cmd(cmd: 'ct_show', opts: {})).to include(status: true)
      allow(OsCtld::Command).to receive(:find).with(name).and_return(nil)
      allow(OsCtld::Eventd).to receive(:report)
      handler = OsCtld::Daemon::ClientHandler.new(nil, {})
      allow(OsCtld::Commands::Container::Stop).to receive(:new).and_call_original
      allow(OsCtld::Commands::Container::Restart).to receive(:new).and_call_original
      expect { handler.handle_cmd(cmd: name.to_s, opts: options) }.to raise_error(
        OsCtld::CommandFailed, /Unsupported command/
      )
      expect(OsCtld::Commands::Container::Stop).not_to have_received(:new)
      expect(OsCtld::Commands::Container::Restart).not_to have_received(:new)
    end
  end
end

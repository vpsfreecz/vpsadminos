# frozen_string_literal: true

require 'tmpdir'

load File.expand_path(
  '../../../os/modules/system/activation/switch-to-configuration.rb',
  __dir__
)

RSpec.describe OsctldRestart do
  let(:service_class) do
    Class.new do
      def stop; end

      def start; end

      def running? = false
    end
  end
  let(:service) { instance_spy(service_class) }
  let(:services) do
    instance_double(
      Services,
      osctld_restart: service,
      osctld_target: service
    )
  end

  def coordinator(status:, commands: {}, coordinator_services: services, **opts)
    klass = Class.new(described_class) do
      attr_accessor :test_status, :test_commands, :test_wait_service_down,
                    :test_nodectld_remote, :test_service_supervised,
                    :test_svc, :test_target_nodectld_barrier,
                    :test_nodectld_unpaused, :test_service_process_identity
      attr_reader :calls, :nodectld_calls, :svc_calls

      protected

      def osctl_json(*) = test_status

      def run_osctl(*args)
        @calls ||= []
        @calls << args
        result = test_commands.fetch(args, true)
        result.is_a?(Array) ? result.shift : result
      end

      def wait_service_down = test_wait_service_down

      def nodectld_remote(command)
        @nodectld_calls ||= []
        @nodectld_calls << command
        test_nodectld_remote != false
      end

      def wait_nodectld_remote(command)
        nodectld_remote(command)
      end

      def service_supervised?(_name)
        test_service_supervised != false
      end

      def run_svc(option, name)
        @svc_calls ||= []
        @svc_calls << [option, name]
        test_svc != false
      end

      def target_nodectld_barrier_active?
        test_target_nodectld_barrier != false
      end

      def nodectld_unpaused?
        value = test_nodectld_unpaused
        value = value.shift if value.is_a?(Array)
        value != false
      end

      def service_process_identity(_name)
        test_service_process_identity
      end
    end
    default_down_path = !opts.has_key?(:nodectld_down_path)
    opts = {
      nodectld_down_path: File.join(
        Dir.tmpdir,
        "osctld-switch-#{Process.pid}-#{Thread.current.object_id}.down"
      )
    }.merge(opts)
    FileUtils.rm_f(opts[:nodectld_down_path]) if default_down_path
    ret = klass.new(coordinator_services, dry_run: false, **opts)
    ret.test_status = status
    ret.test_commands = commands
    ret.test_wait_service_down = true
    ret.test_nodectld_remote = true
    ret.test_service_supervised = true
    ret.test_svc = true
    ret.test_target_nodectld_barrier = true
    ret.test_nodectld_unpaused = true
    ret.test_service_process_identity = {
      'pid' => 123,
      'start_time_ticks' => 456
    }
    ret
  end

  it 'drains the old daemon before asking runit to stop it' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false }
    )

    restart.prepare

    expect(restart.calls).to eq([%w[daemon prepare-stop]])
    expect(service).to have_received(:stop).once
  end

  it 'resumes admission and leaves the service running when drain fails' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false },
      commands: { %w[daemon prepare-stop] => false }
    )

    expect { restart.prepare }.to raise_error(
      RuntimeError,
      'osctld lifecycle drain failed before activation'
    )
    expect(restart.calls).to eq(
      [%w[daemon prepare-stop], %w[daemon resume]]
    )
    expect(service).not_to have_received(:stop)
  end

  it 'starts the target daemon before waiting for readiness' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false }
    )

    restart.start_and_wait

    expect(service).to have_received(:start).once
    expect(restart.calls).to eq([%w[daemon wait-ready --timeout 300]])
  end

  it 'keeps nodectld responsive through a logical legacy pause until readiness' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    allow(restart).to receive(:persist_nodectld_pause)

    restart.send(:pause_legacy_nodectld)
    expect(restart.nodectld_calls).to eq([:pause])
    expect(restart.svc_calls).to eq([%w[-o nodectld]])

    restart.start_and_wait
    expect(restart.nodectld_calls).to eq([:pause])

    restart.resume_nodectld
    expect(restart.nodectld_calls).to eq(%i[pause resume])
    expect(restart.svc_calls).to eq(
      [%w[-o nodectld], %w[-d nodectld], %w[-u nodectld]]
    )
  end

  it 'holds nodectld down across a runsv supervisor replacement' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      down_path = File.join(dir, 'nodectld-down')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      restart = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        nodectld_pause_path: pause_path,
        nodectld_down_path: down_path,
        boot_id_path:
      )

      restart.send(:pause_legacy_nodectld)

      expect(File.read(down_path)).to eq(
        OsctldRestart::NODECTLD_DOWN_CONTENT
      )
      expect(JSON.parse(File.read(pause_path))).to include(
        'phase' => 'supervision-held',
        'service_down_created' => true
      )

      restart.start_and_wait
      expect(File).not_to exist(down_path)
      expect(restart.svc_calls).to eq(
        [%w[-o nodectld], %w[-d nodectld], %w[-u nodectld]]
      )
    end
  end

  it 'recovers the exact nodectld identity when interrupted while acquiring the hold' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      down_path = File.join(dir, 'nodectld-down')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      old_pid = Process.spawn('sleep', '30')
      replacement_pid = Process.spawn('sleep', '30')
      identities = [old_pid, replacement_pid].to_h do |pid|
        stat = File.read("/proc/#{pid}/stat")
        tail = stat[stat.rindex(')') + 2..]
        [pid, { 'pid' => pid, 'start_time_ticks' => tail.split.fetch(19).to_i }]
      end
      options = {
        nodectld_pause_path: pause_path,
        nodectld_down_path: down_path,
        boot_id_path:,
        service_stop_timeout: 2
      }
      first = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        **options
      )
      first.test_service_process_identity = identities.fetch(old_pid)
      allow(first).to receive(:persist_nodectld_pause).and_wrap_original do |method, phase:|
        throw :coordinator_killed if phase == 'supervision-held'

        method.call(phase:)
      end

      catch(:coordinator_killed) { first.send(:pause_legacy_nodectld) }

      expect(File.read(down_path)).to eq(
        OsctldRestart::NODECTLD_DOWN_CONTENT
      )
      expect(JSON.parse(File.read(pause_path))).to include(
        'phase' => 'acquiring-supervision',
        'service_down_created' => false,
        'service_process' => identities.fetch(old_pid)
      )

      retry_restart = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        **options
      )
      retry_restart.test_service_process_identity = identities.fetch(replacement_pid)
      allow(retry_restart).to receive(:service_process_identity).and_call_original

      retry_restart.send(:pause_legacy_nodectld)
      old_waiter = Thread.new { Process.wait(old_pid) }
      expect(retry_restart.send(:stop_recorded_legacy_nodectld)).to be(true)

      old_waiter.join
      expect { Process.kill(0, old_pid) }.to raise_error(Errno::ESRCH)
      expect { Process.kill(0, replacement_pid) }.not_to raise_error
      expect(JSON.parse(File.read(pause_path))).to include(
        'phase' => 'supervision-held',
        'service_down_created' => true,
        'service_process' => identities.fetch(old_pid)
      )
      expect(retry_restart).not_to have_received(:service_process_identity)
    ensure
      [old_pid, replacement_pid].compact.each do |pid|
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      old_waiter&.join
    end
  end

  it 'resumes nodectld again when it restarts across marker removal' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      restart = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        nodectld_pause_path: pause_path,
        nodectld_down_path: File.join(dir, 'nodectld-down'),
        boot_id_path:
      )
      restart.test_nodectld_unpaused = [false, true]
      allow(restart).to receive(:monotonic_now).and_return(0)
      allow(restart).to receive(:sleep)
      restart.send(:pause_legacy_nodectld)

      restart.resume_nodectld

      expect(restart.nodectld_calls).to eq(%i[pause resume resume])
      expect(File).not_to exist(pause_path)
    end
  end

  it 'reclaims a down hold and repeats pause after coordinator interruption' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      down_path = File.join(dir, 'nodectld-down')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      options = {
        nodectld_pause_path: pause_path,
        nodectld_down_path: down_path,
        boot_id_path:
      }
      first = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        **options
      )
      first.send(:pause_legacy_nodectld)

      retry_restart = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        **options
      )
      retry_restart.send(:pause_legacy_nodectld)

      expect(retry_restart.nodectld_calls).to eq([:pause])
      expect(retry_restart.svc_calls).to eq([%w[-o nodectld]])
      expect(File.read(down_path)).to eq(
        OsctldRestart::NODECTLD_DOWN_CONTENT
      )
    end
  end

  it 'refuses to start osctld behind a target nodectld without the barrier' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      down_path = File.join(dir, 'nodectld-down')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      restart = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        nodectld_pause_path: pause_path,
        nodectld_down_path: down_path,
        boot_id_path:
      )
      restart.test_target_nodectld_barrier = false
      allow(restart).to receive(:monotonic_now).and_return(0, 0, 61)
      allow(restart).to receive(:sleep)

      restart.send(:pause_legacy_nodectld)

      expect { restart.start_and_wait }.to raise_error(
        RuntimeError,
        'target nodectld did not honor the restart barrier'
      )
      expect(service).not_to have_received(:start)
      expect(File).to exist(pause_path)
    end
  end

  it 'terminates the exact legacy nodectld left by a dead supervisor' do
    Dir.mktmpdir do |dir|
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      restart = described_class.new(
        services,
        dry_run: false,
        nodectld_pause_path: File.join(dir, 'pause.json'),
        nodectld_down_path: File.join(dir, 'down'),
        boot_id_path:,
        service_stop_timeout: 2
      )
      pid = Process.spawn('sleep', '30')
      stat = File.read("/proc/#{pid}/stat")
      tail = stat[stat.rindex(')') + 2..]
      restart.instance_variable_set(
        :@legacy_nodectld_identity,
        {
          'pid' => pid,
          'start_time_ticks' => tail.split.fetch(19).to_i
        }
      )
      waiter = Thread.new { Process.wait(pid) }

      expect(restart.send(:stop_recorded_legacy_nodectld)).to be(true)
      waiter.join
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    ensure
      begin
        Process.kill('KILL', pid) if pid
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      waiter&.join
    end
  end

  it 'does not pause nodectld when its runit service is absent' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    restart.test_service_supervised = false
    allow(restart).to receive(:persist_nodectld_pause)

    restart.send(:pause_legacy_nodectld)

    expect(restart).not_to have_received(:persist_nodectld_pause)
    expect(restart.nodectld_calls).to be_nil
    expect(restart.svc_calls).to be_nil
  end

  it 'waits for paused nodectld workers and subprocesses to drain' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    busy = {
      'status' => 'ok',
      'response' => {
        'queues' => { 'vps' => { 'workers' => { '1' => {} } } },
        'subprocesses' => {}
      }
    }
    idle = {
      'status' => 'ok',
      'response' => {
        'queues' => { 'vps' => { 'workers' => {} } },
        'subprocesses' => {}
      }
    }
    allow(restart).to receive(:nodectld_remote_reply)
      .with(:status).and_return(busy, idle)
    allow(restart).to receive(:monotonic_now).and_return(0)
    allow(restart).to receive(:sleep)

    expect(restart.send(:wait_for_legacy_nodectld_idle)).to be(true)
    expect(restart).to have_received(:sleep).with(0.2).once
  end

  it 'attests only containers live in the latest legacy snapshot' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    restart.send(
      :replace_runtime_handoff,
      [
        { 'pool' => 'tank', 'id' => '101', 'state' => 'running' },
        { 'pool' => 'tank', 'id' => '102', 'state' => 'stopped' }
      ]
    )
    expect(restart.instance_variable_get(:@handoff_runtime)).to eq(
      [%w[tank 101]]
    )

    restart.send(
      :replace_runtime_handoff,
      [{ 'pool' => 'tank', 'id' => '101', 'state' => 'stopped' }]
    )
    expect(restart.instance_variable_get(:@handoff_runtime)).to be_empty
  end

  it 'does not turn an in-flight legacy stop into desired running state' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true },
      legacy_stable_window: 0
    )
    stopping = {
      'pool' => 'tank',
      'id' => '101',
      'state' => 'stopping',
      'autostart' => true,
      'autostart_priority' => 17
    }
    stopped = stopping.merge('state' => 'stopped')
    allow(restart).to receive(:osctl_json).and_return(
      [stopping],
      [stopped],
      [stopped]
    )
    allow(restart).to receive_messages(
      legacy_manager_signature: [],
      monotonic_now: 0,
      sleep: nil,
      write_handoff: nil
    )

    restart.send(:wait_for_legacy_stability)

    expect(restart.instance_variable_get(:@handoff_desired)).to be_empty
    expect(restart.instance_variable_get(:@handoff_active)).to be_empty
    expect(restart.instance_variable_get(:@handoff_runtime)).to be_empty
  end

  it 'recovers a durable nodectld pause after target readiness fails' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      options = { nodectld_pause_path: pause_path, boot_id_path: }
      restart = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        **options
      )
      allow(restart).to receive(:wait_for_target_ready).and_return(false)

      restart.send(:pause_legacy_nodectld)
      expect { restart.start_and_wait }.to raise_error(
        RuntimeError,
        'target osctld did not become ready within 300 seconds'
      )
      expect(File).to exist(pause_path)

      retry_services = instance_double(
        Services,
        osctld_restart: nil,
        osctld_target: service
      )
      retry_restart = coordinator(
        status: { 'initialized' => true, 'legacy' => false },
        coordinator_services: retry_services,
        **options
      )
      allow(retry_restart).to receive(:wait_for_target_ready).and_return(true)

      retry_restart.start_and_wait
      retry_restart.resume_nodectld

      expect(retry_restart.nodectld_calls).to eq([:resume])
      expect(retry_restart.svc_calls).to eq(
        [%w[-d nodectld], %w[-u nodectld]]
      )
      expect(File).not_to exist(pause_path)
    end
  end

  it 'recovers a direct restart when osctld is down behind a pause barrier' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      File.write(
        pause_path,
        JSON.generate(
          'schema' => 1,
          'boot_id' => 'boot-1',
          'reason' => 'osctld-restart'
        )
      )
      restart = coordinator(
        status: { 'initialized' => true, 'legacy' => false },
        nodectld_pause_path: pause_path,
        boot_id_path:
      )
      allow(restart).to receive(:service_running?).with('osctld').and_return(false)
      allow(restart).to receive(:wait_for_target_ready).and_return(true)

      restart.prepare
      restart.start_and_wait
      restart.resume_nodectld

      expect(restart.calls).to be_nil
      expect(service).not_to have_received(:stop)
      expect(service).to have_received(:start).once
      expect(restart.nodectld_calls).to eq([:resume])
      expect(File.exist?(pause_path)).to be(false)
    end
  end

  it 'fails closed when the nodectld pause barrier is malformed' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      File.write(pause_path, '{')

      expect do
        coordinator(
          status: { 'initialized' => true, 'legacy' => false },
          nodectld_pause_path: pause_path,
          boot_id_path:
        )
      end.to raise_error(
        RuntimeError,
        /invalid nodectld restart barrier/
      )
    end
  end

  it 'uses non-waiting sv controls for nodectld supervision' do
    Dir.mktmpdir do |dir|
      restart = described_class.new(
        services,
        dry_run: false,
        nodectld_pause_path: File.join(dir, 'pause.json')
      )
      allow(restart).to receive(:system).and_return(true)

      expect(restart.send(:run_svc, '-o', 'nodectld')).to be(true)
      expect(restart).to have_received(:system).with(
        File.join(Configuration::CURRENT_BIN, 'sv'),
        'o',
        'nodectld'
      )
    end
  end

  it 'fails closed when the nodectld pause reason is unsupported' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      File.write(
        pause_path,
        JSON.generate(
          'schema' => 1,
          'boot_id' => 'boot-1',
          'reason' => 'future-coordinator'
        )
      )

      expect do
        coordinator(
          status: { 'initialized' => true, 'legacy' => false },
          nodectld_pause_path: pause_path,
          boot_id_path:
        )
      end.to raise_error(
        RuntimeError,
        /invalid nodectld restart barrier/
      )
    end
  end

  it 'retains a durable nodectld pause when the resume RPC fails' do
    Dir.mktmpdir do |dir|
      pause_path = File.join(dir, 'nodectld-pause.json')
      boot_id_path = File.join(dir, 'boot-id')
      File.write(boot_id_path, "boot-1\n")
      options = { nodectld_pause_path: pause_path, boot_id_path: }
      restart = coordinator(
        status: { 'initialized' => true, 'legacy' => true },
        **options
      )
      restart.send(:pause_legacy_nodectld)
      restart.test_nodectld_remote = false

      expect { restart.resume_nodectld }.to raise_error(
        RuntimeError,
        'unable to resume nodectld after target osctld readiness'
      )
      expect(File).to exist(pause_path)

      retry_services = instance_double(
        Services,
        osctld_restart: nil,
        osctld_target: service
      )
      retry_restart = coordinator(
        status: { 'initialized' => true, 'legacy' => false },
        coordinator_services: retry_services,
        **options
      )
      allow(retry_restart).to receive(:wait_for_target_ready).and_return(true)

      retry_restart.start_and_wait
      retry_restart.resume_nodectld

      expect(retry_restart.nodectld_calls).to eq([:resume])
      expect(File).not_to exist(pause_path)
    end
  end

  it 'retries readiness when the target daemon socket is not available yet' do
    args = %w[daemon wait-ready --timeout 300]
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false },
      commands: { args => [false, true] }
    )
    allow(restart).to receive(:monotonic_now).and_return(0)
    allow(restart).to receive(:sleep)

    restart.start_and_wait

    expect(restart.calls).to eq([args, args])
    expect(restart).to have_received(:sleep).with(0.2).once
  end

  it 'recovers a same-boot handoff left after the legacy daemon stopped' do
    handoff = {
      'schema' => 1,
      'boot_id' => 'boot-1',
      'created_at' => 1.0,
      'containers' => [
        {
          'pool' => 'tank',
          'id' => '101',
          'source' => 'legacy-runtime-upgrade'
        }
      ],
      'runtime_containers' => []
    }
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read)
      .with(OsctldRestart::HANDOFF_PATH)
      .and_return(JSON.generate(handoff))
    allow(File).to receive(:read)
      .with(OsctldRestart::BOOT_ID_PATH)
      .and_return("boot-1\n")
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    allow(restart).to receive(:service_running?).with('osctld').and_return(false)
    allow(restart).to receive(:wait_for_target_ready).and_return(true)

    restart.prepare
    restart.start_and_wait

    expect(restart.calls).to be_nil
    expect(service).not_to have_received(:stop)
    expect(service).to have_received(:start).once
    expect(restart.instance_variable_get(:@handoff_desired)).to eq(
      [%w[tank 101]]
    )
  end

  it 'fails closed on an invalid current runtime handoff' do
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read)
      .with(OsctldRestart::HANDOFF_PATH)
      .and_return('{')
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )

    expect do
      restart.send(:current_boot_handoff?)
    end.to raise_error(
      RuntimeError,
      /invalid osctld runtime handoff/
    )
  end

  it 'fails closed when a current handoff has a malformed priority' do
    handoff = {
      'schema' => 1,
      'boot_id' => 'boot-1',
      'created_at' => 1.0,
      'containers' => [
        {
          'pool' => 'tank',
          'id' => '101',
          'source' => 'legacy-runtime-upgrade',
          'priority' => '17'
        }
      ],
      'runtime_containers' => []
    }
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read)
      .with(OsctldRestart::HANDOFF_PATH)
      .and_return(JSON.generate(handoff))
    allow(File).to receive(:read)
      .with(OsctldRestart::BOOT_ID_PATH)
      .and_return("boot-1\n")
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )

    expect do
      restart.send(:current_boot_handoff?)
    end.to raise_error(
      RuntimeError,
      /invalid osctld runtime handoff/
    )
  end

  it 'fails closed on conflicting duplicate current handoff entries' do
    handoff = {
      'schema' => 1,
      'boot_id' => 'boot-1',
      'created_at' => 1.0,
      'containers' => [
        {
          'pool' => 'tank',
          'id' => '101',
          'source' => 'legacy-runtime-upgrade',
          'priority' => 17
        },
        {
          'pool' => 'tank',
          'id' => '101',
          'source' => 'legacy-runtime-upgrade',
          'priority' => 18
        }
      ],
      'runtime_containers' => []
    }
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read)
      .with(OsctldRestart::HANDOFF_PATH)
      .and_return(JSON.generate(handoff))
    allow(File).to receive(:read)
      .with(OsctldRestart::BOOT_ID_PATH)
      .and_return("boot-1\n")
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )

    expect do
      restart.send(:current_boot_handoff?)
    end.to raise_error(
      RuntimeError,
      /conflicting duplicate in osctld runtime handoff/
    )
  end

  it 'restores the current runit service when it cannot stop before activation' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => false }
    )
    restart.test_wait_service_down = false

    expect { restart.prepare }.to raise_error(
      RuntimeError,
      'osctld supervisor did not stop within 60 seconds'
    )
    expect(service).to have_received(:start).once
    expect(restart.calls).to eq(
      [%w[daemon prepare-stop], %w[daemon resume]]
    )
  end

  it 'retains the durable handoff when legacy queue restoration fails' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true },
      commands: {
        ['--pool', 'tank', 'ct', 'start', '--queue', '--priority', '10', '101'] => false
      }
    )
    restart.instance_variable_set(:@legacy, true)
    restart.instance_variable_set(
      :@handoff_queues,
      [{ 'pool' => 'tank', 'id' => '101', 'priority' => 10 }]
    )
    restart.instance_variable_set(:@legacy_cancelled_pools, ['tank'])
    allow(restart).to receive(:legacy_queue_contains?).and_return(false)
    allow(FileUtils).to receive(:rm_f)

    expect do
      restart.send(:restore_legacy_handoff)
    end.to raise_error(
      RuntimeError,
      %r{retaining /run/osctl/upgrade-handoff.yml}
    )
    expect(FileUtils).not_to have_received(:rm_f).with(
      OsctldRestart::HANDOFF_PATH
    )
  end

  it 'requeues an active autostart which settles stopped before rollback' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    restart.instance_variable_set(:@legacy, true)
    restart.instance_variable_set(
      :@handoff_active,
      [{ 'pool' => 'tank', 'id' => '101', 'priority' => 17 }]
    )
    restart.instance_variable_set(:@handoff_desired, [%w[tank 101]])
    restart.instance_variable_set(
      :@current_handoff_observed,
      [%w[tank 101]]
    )
    allow(restart).to receive_messages(
      legacy_started_containers: [],
      legacy_queue_contains?: false
    )
    allow(FileUtils).to receive(:rm_f)

    restart.send(:restore_legacy_handoff)

    expect(restart.calls).to eq(
      [
        [
          '--pool', 'tank', 'ct', 'start', '--queue',
          '--priority', '17', '101'
        ]
      ]
    )
    expect(restart.instance_variable_get(:@handoff_desired)).to be_empty
    expect(FileUtils).to have_received(:rm_f)
      .with(OsctldRestart::HANDOFF_PATH).once
  end

  it 'restores each cancelled legacy queue entry only once' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    entry = { 'pool' => 'tank', 'id' => '101', 'priority' => 10 }
    restart.instance_variable_set(:@legacy, true)
    restart.instance_variable_set(:@handoff_queues, [entry])
    restart.instance_variable_set(:@legacy_cancelled_pools, ['tank'])
    allow(restart).to receive(:legacy_queue_contains?).and_return(true)
    allow(FileUtils).to receive(:rm_f)

    2.times { restart.send(:restore_legacy_handoff) }

    expect(restart.calls).to be_nil
    expect(FileUtils).to have_received(:rm_f)
      .with(OsctldRestart::HANDOFF_PATH).twice
  end

  it 'removes the handoff after compensating a partially cancelled snapshot' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    restart.instance_variable_set(:@legacy, true)
    restart.instance_variable_set(
      :@handoff_queues,
      [
        { 'pool' => 'tank', 'id' => '101', 'priority' => 10 },
        { 'pool' => 'cold', 'id' => '202', 'priority' => 20 }
      ]
    )
    restart.instance_variable_set(
      :@handoff_desired,
      [%w[tank 101], %w[cold 202]]
    )
    restart.instance_variable_set(
      :@current_handoff_observed,
      [%w[tank 101], %w[cold 202]]
    )
    restart.instance_variable_set(:@legacy_cancelled_pools, ['tank'])
    allow(restart).to receive(:legacy_queue_contains?)
      .with('tank', '101')
      .and_return(true)
    allow(FileUtils).to receive(:rm_f)

    restart.send(:restore_legacy_handoff)

    expect(restart.instance_variable_get(:@handoff_queues)).to be_empty
    expect(restart.instance_variable_get(:@handoff_desired)).to be_empty
    expect(FileUtils).to have_received(:rm_f)
      .with(OsctldRestart::HANDOFF_PATH).once
  end

  it 'merges a current-boot handoff left by an interrupted coordinator' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    handoff = {
      'schema' => 1,
      'boot_id' => 'boot-1',
      'created_at' => 1.0,
      'containers' => [
        {
          'pool' => 'tank',
          'id' => '101',
          'source' => 'legacy-runtime-upgrade',
          'priority' => 17
        },
        {
          'pool' => 'tank',
          'id' => '102',
          'source' => 'legacy-runtime-upgrade'
        }
      ],
      'runtime_containers' => []
    }
    allow(File).to receive(:read)
      .with(OsctldRestart::HANDOFF_PATH)
      .and_return(JSON.generate(handoff))
    allow(File).to receive(:read)
      .with(OsctldRestart::BOOT_ID_PATH)
      .and_return("boot-1\n")

    restart.send(:merge_existing_handoff)

    expect(restart.instance_variable_get(:@handoff_desired)).to eq(
      [%w[tank 101], %w[tank 102]]
    )
    expect(restart.instance_variable_get(:@handoff_active)).to eq(
      [{ 'pool' => 'tank', 'id' => '101', 'priority' => 17 }]
    )
  end

  it 'retains handoff entries without proof that legacy intent was restored' do
    restart = coordinator(
      status: { 'initialized' => true, 'legacy' => true }
    )
    restart.instance_variable_set(:@legacy, true)
    restart.instance_variable_set(
      :@handoff_desired,
      [%w[tank inherited], %w[tank current]]
    )
    restart.instance_variable_set(
      :@current_handoff_observed,
      [%w[tank current]]
    )
    allow(restart).to receive(:write_handoff)
    allow(FileUtils).to receive(:rm_f)

    restart.send(:restore_legacy_handoff)

    expect(restart.instance_variable_get(:@handoff_desired)).to eq(
      [%w[tank inherited], %w[tank current]]
    )
    expect(restart).to have_received(:write_handoff).once
    expect(FileUtils).not_to have_received(:rm_f).with(
      OsctldRestart::HANDOFF_PATH
    )
  end

  describe Services do
    def service(name)
      service_class = Class.new do
        def name; end

        def skip?; end

        def start; end

        def stop; end
      end
      instance_spy(service_class, name:, skip?: false)
    end

    it 'defers a changed nodectld restart until osctld is ready' do
      services = described_class.allocate
      osctld = service('osctld')
      nodectld = service('nodectld')
      other = service('other')
      allow(services).to receive(:restart).and_return(
        [osctld, nodectld, other]
      )

      expect(services.restart_before_osctld).to eq([other])
      expect(services.deferred_restart_after_osctld).to eq([nodectld])
      expect(services.restart_after_osctld).to eq([nodectld, other])
      expect(
        services.deferred_restart_after_osctld(nodectld_restarted: true)
      ).to be_empty
      expect(
        services.restart_after_osctld(nodectld_restarted: true)
      ).to eq([other])
    end
  end
end

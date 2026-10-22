# frozen_string_literal: true

require 'osctld/attributes'
require 'osctld/pool'
require 'osctld/exceptions'
require 'osctld/garbage_collector'
require 'osctld/container/run_id'
require 'osctld/container/run_configuration'
require 'osctld/manipulable'
require 'osctld/trash_bin'

RSpec.describe OsCtld::Pool do
  def build_pool(root:, name: 'tank', dataset: 'tank')
    conf_path = File.join(root, 'conf')
    repo_path = File.join(root, 'repo')
    log_path = File.join(root, 'log')

    FileUtils.mkdir_p(File.join(conf_path, 'pool'))
    FileUtils.mkdir_p(repo_path)
    FileUtils.mkdir_p(log_path)

    described_class.new(name, dataset).tap do |pool|
      allow(pool).to receive_messages(
        conf_path: conf_path,
        repo_path: repo_path,
        log_path: log_path
      )
    end
  end

  it 'uses default parallel start and stop values' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)

      expect(pool.parallel_start).to eq(2)
      expect(pool.parallel_stop).to eq(4)
    end
  end

  it 'loads explicit options and attrs from the config file' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)
      write_yaml_file(pool.config_path, {
        'parallel_start' => 3,
        'parallel_stop' => 5,
        'attrs' => { 'org.vpsfree.cz/test:role' => 'production' }
      })

      pool.send(:load_config)

      expect(pool.parallel_start).to eq(3)
      expect(pool.parallel_stop).to eq(5)
      expect(pool.attrs['org.vpsfree.cz/test:role']).to eq('production')
    end
  end

  it 'round-trips attrs through the pool config file' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)

      pool.set(attrs: { 'org.vpsfree.cz/test:role' => 'production' })

      reloaded = build_pool(root: dir)
      reloaded.send(:load_config)

      expect(reloaded.attrs['org.vpsfree.cz/test:role']).to eq('production')
      expect(load_yaml_file(pool.config_path)).to eq(
        'attrs' => { 'org.vpsfree.cz/test:role' => 'production' }
      )
    end
  end

  it 'resizes the autostart plan and persists parallel_start' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)
      autostart_plan = instance_double(OsCtld::AutoStart::Plan, resize: nil)
      autostop_plan = instance_double(OsCtld::AutoStop::Plan, resize: nil)
      pool.instance_variable_set('@autostart_plan', autostart_plan)
      pool.instance_variable_set('@autostop_plan', autostop_plan)

      pool.set(parallel_start: 6)

      expect(autostart_plan).to have_received(:resize).with(6)
      expect(load_yaml_file(pool.config_path)).to include('parallel_start' => 6)
    end
  end

  it 'resizes the autostop plan and persists parallel_stop' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)
      autostart_plan = instance_double(OsCtld::AutoStart::Plan, resize: nil)
      autostop_plan = instance_double(OsCtld::AutoStop::Plan, resize: nil)
      pool.instance_variable_set('@autostart_plan', autostart_plan)
      pool.instance_variable_set('@autostop_plan', autostop_plan)

      pool.set(parallel_stop: 7)

      expect(autostop_plan).to have_received(:resize).with(7)
      expect(load_yaml_file(pool.config_path)).to include('parallel_stop' => 7)
    end
  end

  it 'updates and removes custom attributes' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)

      pool.set(attrs: { 'org.vpsfree.cz/test:role' => 'production' })
      expect(pool.attrs['org.vpsfree.cz/test:role']).to eq('production')

      pool.unset(attrs: ['org.vpsfree.cz/test:role'])

      expect(pool.attrs.dump).to eq({})
      expect(load_yaml_file(pool.config_path)).to eq('attrs' => {})
    end
  end

  it 'does not raise when unsetting an option that is still at its default' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)

      expect do
        pool.unset(options: [:parallel_start])
      end.not_to raise_error

      expect(pool.parallel_start).to eq(2)
    end
  end

  it 'tracks export abortion state' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)
      autostop_plan = instance_double(OsCtld::AutoStop::Plan, clear: nil)
      pool.instance_variable_set('@autostop_plan', autostop_plan)

      pool.begin_export
      expect(pool.abort_export?).to be(false)

      pool.abort_export
      expect(pool.abort_export?).to be(true)
      expect(autostop_plan).to have_received(:clear)
    end
  end

  it 'stops started background services in begin_stop' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)
      autostart_plan = instance_double(OsCtld::AutoStart::Plan, started?: true, stop: nil)
      trash_bin = instance_double(OsCtld::TrashBin, started?: true, stop: nil)
      pool.instance_variable_set('@autostart_plan', autostart_plan)
      pool.instance_variable_set('@trash_bin', trash_bin)

      pool.begin_stop

      expect(autostart_plan).to have_received(:stop)
      expect(trash_bin).to have_received(:stop)
    end
  end

  it 'stops remaining services in all_stop' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)
      autostop_plan = instance_double(OsCtld::AutoStop::Plan, stop: nil)
      hint_updater = instance_double(OsCtld::HintUpdater, stop: nil)
      pool.instance_variable_set('@autostop_plan', autostop_plan)
      pool.instance_variable_set('@hint_updater', hint_updater)

      pool.all_stop

      expect(autostop_plan).to have_received(:stop)
      expect(hint_updater).to have_received(:stop)
    end
  end

  it 'calls begin_stop and all_stop from stop' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)

      allow(pool).to receive(:begin_stop)
      allow(pool).to receive(:all_stop)

      pool.stop

      expect(pool).to have_received(:begin_stop)
      expect(pool).to have_received(:all_stop)
    end
  end

  it 'reports state transitions' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)

      expect(pool.imported?).to be(false)
      expect(pool.active?).to be(false)
      expect(pool.disabled?).to be(false)

      pool.instance_variable_set('@state', :active)
      expect(pool.imported?).to be(true)
      expect(pool.active?).to be(true)

      pool.disable
      expect(pool.disabled?).to be(true)
    end
  end

  it 'builds dataset and config helper paths' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir, dataset: 'tank')

      expect(pool.ct_ds).to eq('tank/ct')
      expect(pool.trash_bin_ds).to eq('tank/trash')
      expect(pool.config_path).to eq(File.join(dir, 'conf', 'pool', 'config.yml'))
    end
  end

  describe 'container import publication and retirement refusal' do
    before { OsCtl::Lib::Logger.setup(:none) }

    def import_fixture(root:, running: true, affected: true)
      pool = build_pool(root:)
      gc = OsCtld::GarbageCollector.new(pool)
      pool.instance_variable_set('@garbage_collector', gc)
      ct_class = Class.new do
        include OsCtld::Manipulable
        attr_accessor :state
        attr_reader :id, :pool, :run_conf

        def initialize(pool)
          init_manipulable
          @pool = pool
          @id = 'ct1'
          @state = :unknown
          @run_conf = Object.new
        end

        def impermanence; end
        def distribution; end
        def fresh_state; end
        def ensure_run_conf; end
      end
      ct = ct_class.new(pool)
      ct.instance_variable_set('@run_conf', instance_double(OsCtld::Container::RunConfiguration))
      allow(ct).to receive_messages(impermanence: affected, distribution: 'nixos',
                                    fresh_state: running ? :running : :stopped)
      allow(pool).to receive(:load_entity).and_return(ct)
      allow(pool).to receive(:ensure_limits)
      allow(pool).to receive(:prepare_container)
      stub_const('OsCtld::ContainerControl::Commands::State', Class.new do
        def self.run!(*, **); end
      end)
      state = Struct.new(:state, :init_pid).new(running ? :running : :stopped, running ? 6498 : nil)
      allow(OsCtld::ContainerControl::Commands::State).to receive(:run!).and_return(state)
      monitor = Class.new { def self.monitor(_ct); end }
      stub_const('OsCtld::Monitor::Master', monitor)
      allow(monitor).to receive(:monitor)
      console = Module.new { def self.reconnect_tty0(_ct); end }
      stub_const('OsCtld::Console', console)
      allow(console).to receive(:reconnect_tty0)
      database = Class.new do
        def self.add(_ct); end
        def self.find(*); end
      end
      stub_const('OsCtld::DB::Containers', database)
      published = []
      allow(database).to receive(:add) { |object| published << object }
      allow(database).to receive(:find) { |id, _pool| published.find { |object| object.id == id } }
      allow(ct.run_conf).to receive(:recover_impermanent_root!) do |_pid, publish:, &preparation|
        preparation.call
        publish.call
      end
      { pool:, ct:, gc:, published:, monitor:, console: }
    end

    it 'holds manipulation through publication and synchronous monitor/console registration' do
      with_tmpdir do |root|
        f = import_fixture(root:)
        attempted_stop = OsCtl::Lib::Queue.new
        allow(f[:monitor]).to receive(:monitor) do |ct|
          expect(f[:published]).to eq([ct])
          expect(ct.state).to eq(:running)
          worker = Thread.new do
            ct.manipulate('stop') { attempted_stop << :entered }
          rescue OsCtld::ResourceLocked
            attempted_stop << :excluded
          end
          expect(attempted_stop.pop(timeout: 1)).to eq(:excluded)
          expect(worker.join(1)).to be(worker)
        end
        allow(f[:console]).to receive(:reconnect_tty0) do |ct|
          expect(ct.is_being_manipulated?).to be(true)
        end
        f[:pool].send(:load_container, 'ct1', nil)
        expect(f[:ct].is_being_manipulated?).to be(false)
        expect(f[:ct]).not_to have_received(:fresh_state)
        expect(f[:pool]).to have_received(:prepare_container).with(f[:ct])
        expect(f[:monitor]).to have_received(:monitor).with(f[:ct])
        expect(f[:console]).to have_received(:reconnect_tty0).with(f[:ct])
      end
    end

    it 'publishes before an asynchronous monitor can refresh its run' do
      with_tmpdir do |root|
        f = import_fixture(root:)
        observations = OsCtl::Lib::Queue.new
        worker = nil
        allow(f[:monitor]).to receive(:monitor) do |ct|
          worker = Thread.new { observations << [f[:published].include?(ct), ct.run_conf, ct.state] }
        end
        f[:pool].send(:load_container, 'ct1', nil)
        expect(observations.pop(timeout: 1)).to eq([true, f[:ct].run_conf, :running])
        expect(worker.join(1)).to be(worker)
      ensure
        worker&.join(1)
      end
    end

    %i[load constructor recovery preparation publication].each do |phase|
      it "omits and fences a #{phase} refusal before publication" do
        with_tmpdir do |root|
          f = import_fixture(root:)
          case phase
          when :load then allow(f[:pool]).to receive(:load_entity).and_return(nil)
          when :constructor
            allow(f[:pool]).to receive(:load_entity).and_call_original
            allow(OsCtld::Container).to receive(:new).and_raise(OsCtld::ConfigError, 'malformed saved runtime YAML')
          when :recovery then allow(f[:ct].run_conf).to receive(:recover_impermanent_root!).and_raise(OsCtld::ConfigError, 'missing saved evidence')
          when :preparation then allow(f[:pool]).to receive(:prepare_container).and_raise(OsCtld::ConfigError, 'setup failed')
          when :publication then allow(OsCtld::DB::Containers).to receive(:add).and_raise(OsCtld::ConfigError, 'host-link conflict')
          end
          allow(f[:pool]).to receive(:log)
          f[:pool].send(:load_container, 'ct1', nil)
          expect(f[:pool]).to have_received(:log).with(:fatal, /omitted and unmanaged.*reclamation is inhibited/)
          expect(f[:published]).to be_empty
          expect(f[:gc].instance_variable_get('@retirement_inhibited')).to be(true)
          expect(f[:monitor]).not_to have_received(:monitor)
        end
      end
    end

    %i[monitor console event].each do |phase|
      it "retains the authenticated published run and inhibits reclamation after #{phase} failure" do
        with_tmpdir do |root|
          f = import_fixture(root:)
          case phase
          when :monitor then allow(f[:monitor]).to receive(:monitor).and_raise('monitor attach failed')
          when :console then allow(f[:console]).to receive(:reconnect_tty0).and_raise('console attach failed')
          when :event
            allow(OsCtld::DB::Containers).to receive(:add) do |ct|
              f[:published] << ct
              raise 'event delivery failed after DB insertion'
            end
          end
          allow(f[:pool]).to receive(:log)
          f[:pool].send(:load_container, 'ct1', nil)
          expect(f[:pool]).to have_received(:log).with(:fatal, /attachment incomplete.*remains managed.*reclamation is inhibited/)
          expect(f[:published]).to eq([f[:ct]])
          expect(f[:gc].instance_variable_get('@retirement_inhibited')).to be(true)
          expect(f[:ct].is_being_manipulated?).to be(false)
        end
      end
    end

    [[false, true], [true, false]].each do |affected, running|
      it "preserves ordinary import order (affected=#{affected}, running=#{running})" do
        with_tmpdir do |root|
          f = import_fixture(root:, affected:, running:)
          allow(f[:ct].run_conf).to receive(:recover_impermanent_root!)
          allow(f[:monitor]).to receive(:monitor) { expect(f[:published]).to be_empty }
          f[:pool].send(:load_container, 'ct1', nil)
          expect(f[:ct].run_conf).not_to have_received(:recover_impermanent_root!)
          expect(f[:published]).to eq([f[:ct]])
          expect(f[:gc].instance_variable_get('@retirement_inhibited')).to be(false)
        end
      end
    end

    it 'inhibits each failed fresh import but resumes ordinary retirement after successful fresh import' do
      with_tmpdir do |root|
        bytes = nil
        3.times do |attempt|
          f = import_fixture(root:)
          run = Struct.new(:run_id).new(OsCtld::Container::RunId.new(pool_name: 'tank', container_id: 'old', timestamp: 1.5))
          ds = OsCtl::Lib::Zfs::Dataset.new('tank/ct/old.impermanence-123abc')
          f[:gc].add_container_run_dataset(run, ds) if attempt == 0
          path = File.join(f[:pool].conf_path, 'pool', 'garbage-collector.yml')
          bytes ||= File.binread(path)
          if attempt < 2
            allow(f[:ct].run_conf).to receive(:recover_impermanent_root!).and_raise(OsCtld::ConfigError, 'still invalid')
          end
          f[:pool].send(:load_container, 'ct1', nil)
          trash = instance_double(OsCtld::TrashBin, add_dataset: nil)
          expect(f[:gc].instance_variable_get('@container_run_datasets').map(&:dump))
            .to eq([{ 'run_id' => run.run_id.dump, 'dataset' => ds.name }])
          f[:pool].instance_variable_set('@trash_bin', trash)
          consumed = OsCtl::Lib::Queue.new
          allow(f[:gc]).to receive(:trash_dataset).and_wrap_original do |method, dataset|
            result = method.call(dataset)
            consumed << [result]
            result
          end
          config = Struct.new(:prune_interval).new(60)
          daemon = Struct.new(:config).new(Struct.new(:garbage_collector).new(config))
          stub_const('OsCtld::Daemon', Class.new { def self.get; end })
          allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
          f[:gc].start
          f[:gc].prune
          expect(consumed.pop(timeout: 1)).to eq([attempt == 2])
          f[:gc].stop
          if attempt < 2
            expect(File.binread(path)).to eq(bytes)
            expect(trash).not_to have_received(:add_dataset)
          else
            expect(load_yaml_file(path)).to eq('container_run_datasets' => [])
            expect(trash).to have_received(:add_dataset).with(have_attributes(name: ds.name))
          end
        ensure
          f&.dig(:gc)&.stop
        end
      end
    end
  end
end

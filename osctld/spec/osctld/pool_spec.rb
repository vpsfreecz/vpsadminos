# frozen_string_literal: true

require 'osctld/attributes'
require 'osctld/console'
require 'osctld/pool'

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

  it 'retries console attachment resource exhaustion without a lifecycle cutoff' do
    with_tmpdir do |dir|
      pool = build_pool(root: dir)
      ct = Struct.new(:id).new('ct1')
      run_conf = Object.new
      attempts = 0
      daemon_class = stub_const('OsCtld::Daemon', Class.new do
        def self.get; end

        def stopping?; end
      end)
      daemon = instance_double(daemon_class, stopping?: false)
      allow(daemon_class).to receive(:get).and_return(daemon)
      allow(OsCtld::Console).to receive(:reconnect_tty0) do
        attempts += 1
        raise Errno::EMFILE if attempts < 3

        true
      end
      allow(OsCtld::Console).to receive(:wrapper_exited)
      allow(pool).to receive(:sleep)
      allow(pool).to receive(:log)

      pool.send(:reconnect_ct_console, ct, run_conf, cleanup_on_gone: true)

      expect(attempts).to eq(3)
      expect(pool).to have_received(:sleep).with(0.1).ordered
      expect(pool).to have_received(:sleep).with(0.2).ordered
      expect(OsCtld::Console).not_to have_received(:wrapper_exited)
    end
  end
end

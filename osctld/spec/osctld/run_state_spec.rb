# frozen_string_literal: true

require 'osctld/run_state'
require 'osctld/run_state/start_config'

RSpec.describe OsCtld::RunState do
  let(:root) { Dir.mktmpdir('osctld-run-state') }

  let(:paths) do
    {
      rundir: File.join(root, 'run', 'osctl'),
      pool_dir: File.join(root, 'run', 'osctl', 'pools'),
      user_control_dir: File.join(root, 'run', 'osctl', 'user-control'),
      send_receive_dir: File.join(root, 'run', 'osctl', 'send-receive'),
      repository_dir: File.join(root, 'run', 'osctl', 'repository'),
      hook_dir: File.join(root, 'run', 'osctl', 'hooks'),
      daemon_hook_dir: File.join(root, 'run', 'osctl', 'hooks', 'daemon'),
      config_dir: File.join(root, 'run', 'osctl', 'configs'),
      osctld_config_dir: File.join(root, 'run', 'osctl', 'configs', 'osctld'),
      lxc_config_dir: File.join(root, 'run', 'osctl', 'configs', 'lxc'),
      apparmor_dir: File.join(root, 'run', 'osctl', 'configs', 'apparmor'),
      cpu_scheduler_dir: File.join(root, 'run', 'osctl', 'cpu-scheduler')
    }
  end

  after do
    FileUtils.remove_entry(root)
  end

  before do
    send_receive = Module.new do
      def self.assets(_add); end
    end
    send_receive.const_set(:UID, 1234)
    stub_const('OsCtld::SendReceive', send_receive)

    repository = Module.new
    repository.const_set(:UID, 2345)
    stub_const('OsCtld::Repository', repository)

    cpu_scheduler = Module.new do
      def self.assets(_add); end
    end
    stub_const('OsCtld::CpuScheduler', cpu_scheduler)

    app_armor = Module.new do
      def self.enabled?
        true
      end
    end
    stub_const('OsCtld::AppArmor', app_armor)

    lxc = Module.new do
      def self.install_lxc_configs(_dir); end
    end
    stub_const('OsCtld::Lxc', lxc)

    stub_const('OsCtld::RunState::RUNDIR', paths[:rundir])
    stub_const('OsCtld::RunState::POOL_DIR', paths[:pool_dir])
    stub_const('OsCtld::RunState::USER_CONTROL_DIR', paths[:user_control_dir])
    stub_const('OsCtld::RunState::SEND_RECEIVE_DIR', paths[:send_receive_dir])
    stub_const('OsCtld::RunState::REPOSITORY_DIR', paths[:repository_dir])
    stub_const('OsCtld::RunState::HOOK_DIR', paths[:hook_dir])
    stub_const('OsCtld::RunState::DAEMON_HOOK_DIR', paths[:daemon_hook_dir])
    stub_const('OsCtld::RunState::CONFIG_DIR', paths[:config_dir])
    stub_const('OsCtld::RunState::OSCTLD_CONFIG_DIR', paths[:osctld_config_dir])
    stub_const('OsCtld::RunState::LXC_CONFIG_DIR', paths[:lxc_config_dir])
    stub_const('OsCtld::RunState::APPARMOR_DIR', paths[:apparmor_dir])
    stub_const('OsCtld::RunState::CPU_SCHEDULER_DIR', paths[:cpu_scheduler_dir])

    allow(OsCtld::Lxc).to receive(:install_lxc_configs)
    allow(OsCtld::SendReceive).to receive(:assets)
    allow(OsCtld::CpuScheduler).to receive(:assets)
    allow(File).to receive(:chown).and_return(0)
  end

  it 'creates the runtime directory layout' do
    described_class.create

    expect(paths.values_at(
             :rundir,
             :pool_dir,
             :user_control_dir,
             :send_receive_dir,
             :repository_dir,
             :hook_dir,
             :daemon_hook_dir,
             :config_dir,
             :osctld_config_dir,
             :lxc_config_dir,
             :apparmor_dir,
             :cpu_scheduler_dir
           )).to all(satisfy { |path| File.directory?(path) })
    expect(OsCtld::Lxc).to have_received(:install_lxc_configs).with(paths[:lxc_config_dir])
  end

  it 'creates directories and updates mode for existing paths' do
    FileUtils.mkdir_p(paths[:rundir], mode: 0o755)

    described_class.mkdir_p(paths[:rundir], 0o711)

    expect(File.stat(paths[:rundir]).mode & 0o777).to eq(0o711)
  end

  it 'registers expected assets and delegates to subsystem assets' do
    collector = Class.new do
      attr_reader :directories

      def initialize
        @directories = []
      end

      def directory(path, **opts)
        @directories << [path, opts]
      end
    end.new

    described_class.assets(collector)

    expect(collector.directories).to include(
      [paths[:rundir], hash_including(desc: 'Runtime configuration', mode: 0o711)],
      [paths[:pool_dir], hash_including(desc: 'Runtime pool configuration', mode: 0o711)],
      [paths[:user_control_dir], hash_including(desc: 'Runtime user configuration', mode: 0o711)],
      [paths[:send_receive_dir], hash_including(desc: 'Send/Receive configuration', user: 1234, mode: 0o100)],
      [paths[:repository_dir], hash_including(desc: 'Home directory for the repository user', user: 2345, mode: 0o700)],
      [paths[:hook_dir], hash_including(desc: 'Runtime hooks', mode: 0o755)],
      [paths[:daemon_hook_dir], hash_including(desc: 'Daemon lifecycle hooks', mode: 0o755)],
      [paths[:config_dir], hash_including(desc: 'Global LXC configuration files', mode: 0o755)],
      [paths[:apparmor_dir], hash_including(desc: 'Shared AppArmor files', mode: 0o755)]
    )
    expect(OsCtld::SendReceive).to have_received(:assets).with(collector)
    expect(OsCtld::CpuScheduler).to have_received(:assets).with(collector)
  end

  it 'opens the start config at the expected path' do
    FileUtils.mkdir_p(paths[:osctld_config_dir])

    start_config = described_class.open_start_config

    expect(start_config).to be_a(OsCtld::RunState::StartConfig)
    expect(start_config.path).to eq(File.join(paths[:osctld_config_dir], 'start-config.json'))
  end

  describe OsCtld::RunState::StartConfig do
    let(:path) { File.join(root, 'start-config.json') }

    it 'reports missing files as absent' do
      start_config = described_class.new(path)

      expect(start_config.exist?).to be(false)
    end

    it 'reports existing json files as present' do
      File.write(path, JSON.dump('key' => 'value'))

      start_config = described_class.new(path)

      expect(start_config.exist?).to be(true)
    end

    it 'deletes an existing config file on close' do
      File.write(path, JSON.dump('key' => 'value'))

      start_config = described_class.new(path)
      start_config.close

      expect(File.exist?(path)).to be(false)
    end

    it 'ignores ENOENT when closing' do
      File.write(path, JSON.dump('key' => 'value'))

      start_config = described_class.new(path)
      File.unlink(path)

      expect { start_config.close }.not_to raise_error
    end
  end
end

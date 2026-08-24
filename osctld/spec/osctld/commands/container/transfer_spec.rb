# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass

require 'stringio'
require 'osctld/command'
require 'osctld/exceptions'
require 'osctld/commands/container/export'
require 'osctld/commands/container/copy'
require 'osctld/commands/container/send_state'

RSpec.describe 'container transfer commands' do
  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  def build_lifecycle(generations = [], residuals: [])
    Struct.new(:runtime_generations, :residuals).new(generations, residuals)
  end

  def stub_transfer_daemon(writeout:)
    config = Struct.new(:writeout) do
      def writeout_dirtied_pages?
        writeout
      end

      def send_receive
        Struct.new(:send_mbuffer).new(nil)
      end
    end.new(writeout)
    daemon = Struct.new(:config).new(config)

    stub_const('OsCtld::Daemon', Class.new do
      def self.get; end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end

  def build_dataset(name, descendants: [])
    Struct.new(:name, :descendants, :relative_name) do
      def to_s
        name
      end
    end.new(name, descendants, File.basename(name))
  end

  def build_send_ct(
    runtime_state: :running, snapshots: ['snap-base'], descendants: [],
    state_snapshot: nil, state_running: nil, lifecycle: build_lifecycle,
    config_state: :ready, config_state_error: nil
  )
    send_log_opts = Struct.new(:cloned, :snapshots).new(false, false)
    send_log = Struct.new(:state, :snapshots, :opts, :token, :state_snapshot, :state_running) do
      def can_send_continue?(stage)
        case stage
        when :incremental
          %i[base incremental].include?(state)
        when :transfer
          state == :incremental
        else
          false
        end
      end
    end.new(:base, snapshots.dup, send_log_opts, 'token-1', state_snapshot, state_running)
    dataset = build_dataset('tank/ct1', descendants:)

    Struct.new(
      :id, :pool, :config_state, :config_state_error, :runtime_state,
      :send_log, :dataset, :save_config_calls, :closed_send_log, :lifecycle,
      keyword_init: true
    ) do
      def manipulate(_cmd, block:, &)
        yield
      end

      def exclusively(&block)
        block.call
      end

      def each_dataset(&block)
        block.call(dataset)
        dataset.descendants.each(&block)
      end

      def close_send_log
        self.closed_send_log = true
      end

      def save_config
        self.save_config_calls += 1
      end
    end.new(
      id: 'ct1',
      pool: Struct.new(:name, :send_receive_key_chain).new('tank', nil),
      config_state:,
      config_state_error:,
      runtime_state:,
      send_log:,
      dataset:,
      save_config_calls: 0,
      closed_send_log: false,
      lifecycle:
    )
  end

  def stub_send_ssh(command, transfer_success:)
    calls = []

    allow(command).to receive(:send_ssh_cmd) do |_key_chain, _opts, argv|
      calls << argv

      raise "unexpected ssh command #{argv.inspect}" unless argv[1] == 'transfer'

      exitstatus = transfer_success ? 0 : 1

      ['sh', '-c', "exit #{exitstatus}"]
    end

    calls
  end

  describe OsCtld::Commands::Container::Export do
    it 'does not truncate output for a running container with a configuration error' do
      stop_class = stub_const('OsCtld::Commands::Container::Stop', Class.new)
      ct = Struct.new(
        :id, :pool, :config_state, :config_state_error, :runtime_state,
        keyword_init: true
      ) do
        def manipulate(_cmd, block:, &)
          yield
        end
      end.new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        config_state: :error,
        config_state_error: {
          source: 'lxc_config',
          message: 'rootfs path is not available'
        },
        runtime_state: :running
      )
      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new)

      with_tmpdir do |dir|
        path = File.join(dir, 'ct1.tar')
        File.write(path, 'existing export')
        command = described_class.new(
          { consistent: true, compression: nil, file: path },
          {}
        )
        allow(command).to receive(:call_cmd!)

        expect do
          command.execute(ct)
        end.to raise_error(
          OsCtld::CommandFailed,
          'container configuration is not ready (state: error): rootfs path is not available'
        )
        expect(File.read(path)).to eq('existing export')
        expect(command).not_to have_received(:call_cmd!).with(stop_class, any_args)
      end
      expect(OsCtl::Lib::Exporter::Zfs).not_to have_received(:new)
    end

    it 'aborts consistent exports when stopping the source container fails' do
      stop_class = Class.new
      stub_const('OsCtld::Commands::Container::Stop', stop_class)
      hook_manager = Class.new do
        def self.list_all_scripts(_ct); end
      end
      stub_const('OsCtld::Hook::Manager', hook_manager)
      ct = Struct.new(
        :id, :pool, :config_state, :config_state_error, :runtime_state,
        :lifecycle, keyword_init: true
      ).new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        config_state: :ready,
        config_state_error: nil,
        runtime_state: :running,
        lifecycle: build_lifecycle
      )
      exporter = instance_double(OsCtl::Lib::Exporter::Zfs)
      command = described_class.new({ consistent: true, compression: nil }, {})

      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new).and_return(exporter)
      allow(OsCtld::Hook::Manager).to receive(:list_all_scripts).and_return([])
      allow(exporter).to receive(:dump_metadata)
      allow(exporter).to receive(:dump_configs)
      allow(exporter).to receive(:dump_user_hook_scripts)
      allow(exporter).to receive(:dump_rootfs).and_yield
      allow(exporter).to receive(:dump_base)
      allow(exporter).to receive(:dump_incremental)
      allow(exporter).to receive(:close)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'stop failed')

      expect do
        command.send(:export, ct, StringIO.new)
      end.to raise_error(OsCtld::CommandFailed, 'stop failed')
      expect(exporter).not_to have_received(:dump_incremental)
    end

    it 'aborts a consistent export when stop quarantines a residual' do
      stop_class = Class.new
      stub_const('OsCtld::Commands::Container::Stop', stop_class)
      hook_manager = Class.new do
        def self.list_all_scripts(_ct); end
      end
      stub_const('OsCtld::Hook::Manager', hook_manager)
      run_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      lifecycle = build_lifecycle(
        [{ 'id' => run_id.dump, 'role' => 'residual' }]
      )
      ct = Struct.new(
        :id, :pool, :config_state, :config_state_error, :runtime_state,
        :lifecycle, keyword_init: true
      ).new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        config_state: :ready,
        config_state_error: nil,
        runtime_state: :running,
        lifecycle:
      )
      exporter = instance_double(OsCtl::Lib::Exporter::Zfs)
      command = described_class.new(
        { consistent: true, compression: nil },
        {}
      )

      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new).and_return(exporter)
      allow(OsCtld::Hook::Manager).to receive(:list_all_scripts).and_return([])
      allow(exporter).to receive(:dump_metadata)
      allow(exporter).to receive(:dump_configs)
      allow(exporter).to receive(:dump_user_hook_scripts)
      allow(exporter).to receive(:dump_rootfs).and_yield
      allow(exporter).to receive(:dump_base)
      allow(exporter).to receive(:dump_incremental)
      allow(exporter).to receive(:close)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(
          status: true,
          output: { lifecycle_state: 'quarantined' }
        )

      expect do
        command.send(:export, ct, StringIO.new)
      end.to raise_error(
        OsCtld::CommandFailed,
        /consistent container export is blocked.*residual/
      )
      expect(exporter).not_to have_received(:dump_incremental)
    end

    it 'cuts over when the running source stops during the base stream' do
      stop_class = Class.new
      start_class = Class.new
      stub_const('OsCtld::Commands::Container::Stop', stop_class)
      stub_const('OsCtld::Commands::Container::Start', start_class)
      hook_manager = Class.new do
        def self.list_all_scripts(_ct); end
      end
      stub_const('OsCtld::Hook::Manager', hook_manager)
      ct = Struct.new(
        :id, :pool, :config_state, :config_state_error, :runtime_state,
        :lifecycle, keyword_init: true
      ).new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        config_state: :ready,
        config_state_error: nil,
        runtime_state: :running,
        lifecycle: build_lifecycle
      )
      exporter = instance_double(OsCtl::Lib::Exporter::Zfs)
      command = described_class.new(
        { consistent: true, compression: nil },
        {}
      )
      events = []

      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new).and_return(exporter)
      allow(OsCtld::Hook::Manager).to receive(:list_all_scripts).and_return([])
      allow(exporter).to receive(:dump_metadata)
      allow(exporter).to receive(:dump_configs)
      allow(exporter).to receive(:dump_user_hook_scripts)
      allow(exporter).to receive(:dump_rootfs).and_yield
      allow(exporter).to receive(:dump_base) do
        events << :base
        ct.runtime_state = :stopped
      end
      allow(exporter).to receive(:dump_incremental) do
        events << :incremental
      end
      allow(exporter).to receive(:close)
      allow(command).to receive(:call_cmd!) do |klass, **|
        events << (klass == stop_class ? :stop : :start)
        { status: true, output: nil }
      end

      command.send(:export, ct, StringIO.new)

      expect(events).to eq(%i[base stop incremental start])
      expect(command).to have_received(:call_cmd!)
        .with(stop_class, id: 'ct1', pool: 'tank')
      expect(command).to have_received(:call_cmd!)
        .with(start_class, id: 'ct1', pool: 'tank', force: true)
    end

    it 'preserves output when a residual already blocks the export' do
      stop_class = Class.new
      stub_const('OsCtld::Commands::Container::Stop', stop_class)
      active_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      residual_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      residual = { 'id' => residual_id.dump, 'role' => 'residual' }
      lifecycle = build_lifecycle(
        [
          { 'id' => active_id.dump, 'role' => 'active' },
          residual
        ],
        residuals: [residual]
      )
      ct = Struct.new(
        :id, :pool, :config_state, :config_state_error, :runtime_state,
        :lifecycle, keyword_init: true
      ) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        config_state: :ready,
        config_state_error: nil,
        runtime_state: :running,
        lifecycle:
      )
      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new)

      with_tmpdir do |dir|
        path = File.join(dir, 'ct1.tar')
        File.write(path, 'existing export')
        command = described_class.new(
          { consistent: true, compression: nil, file: path },
          {}
        )
        allow(command).to receive(:call_cmd!)

        expect do
          command.execute(ct)
        end.to raise_error(
          OsCtld::CommandFailed,
          /consistent container export is blocked.*residual/
        )
        expect(File.read(path)).to eq('existing export')
        expect(command).not_to have_received(:call_cmd!)
      end
      expect(OsCtl::Lib::Exporter::Zfs).not_to have_received(:new)
    end

    it 'preserves output when a stopped source has a runtime generation' do
      run_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      lifecycle = build_lifecycle(
        [{ 'id' => run_id.dump, 'role' => 'active' }]
      )
      ct = Struct.new(
        :id, :pool, :config_state, :config_state_error, :runtime_state,
        :lifecycle, keyword_init: true
      ) do
        def manipulate(_holder, block:, &)
          yield
        end
      end.new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        config_state: :ready,
        config_state_error: nil,
        runtime_state: :stopped,
        lifecycle:
      )
      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new)

      with_tmpdir do |dir|
        path = File.join(dir, 'ct1.tar')
        File.write(path, 'existing export')
        command = described_class.new(
          { consistent: true, compression: nil, file: path },
          {}
        )

        expect do
          command.execute(ct)
        end.to raise_error(
          OsCtld::CommandFailed,
          /consistent container export is blocked.*active/
        )
        expect(File.read(path)).to eq('existing export')
      end
      expect(OsCtl::Lib::Exporter::Zfs).not_to have_received(:new)
    end

    it 'aborts consistent exports when restarting the source container fails' do
      stop_class = Class.new
      start_class = Class.new
      stub_const('OsCtld::Commands::Container::Stop', stop_class)
      stub_const('OsCtld::Commands::Container::Start', start_class)
      hook_manager = Class.new do
        def self.list_all_scripts(_ct); end
      end
      stub_const('OsCtld::Hook::Manager', hook_manager)
      ct = Struct.new(
        :id, :pool, :config_state, :config_state_error, :runtime_state,
        :lifecycle, keyword_init: true
      ).new(
        id: 'ct1',
        pool: Struct.new(:name).new('tank'),
        config_state: :ready,
        config_state_error: nil,
        runtime_state: :running,
        lifecycle: build_lifecycle
      )
      exporter = instance_double(OsCtl::Lib::Exporter::Zfs)
      command = described_class.new({ consistent: true, compression: nil }, {})

      allow(OsCtl::Lib::Exporter::Zfs).to receive(:new).and_return(exporter)
      allow(OsCtld::Hook::Manager).to receive(:list_all_scripts).and_return([])
      allow(exporter).to receive(:dump_metadata)
      allow(exporter).to receive(:dump_configs)
      allow(exporter).to receive(:dump_user_hook_scripts)
      allow(exporter).to receive(:dump_rootfs).and_yield
      allow(exporter).to receive(:dump_base)
      allow(exporter).to receive(:dump_incremental)
      allow(exporter).to receive(:close)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!)
        .with(
          OsCtld::Commands::Container::Start,
          id: 'ct1',
          pool: 'tank',
          force: true
        ).and_raise(OsCtld::CommandFailed, 'start failed')

      expect do
        command.send(:export, ct, StringIO.new)
      end.to raise_error(OsCtld::CommandFailed, 'start failed')
      expect(exporter).to have_received(:dump_incremental)
    end
  end

  describe OsCtld::Commands::Container::SendState do
    before do
      stub_transfer_daemon(writeout: false)
      stub_const('OsCtld::DB::Containers', Class.new do
        def self.find(_id, _pool); end
      end)
      stub_const('OsCtld::Commands::Container::Stop', Class.new)
      stub_const('OsCtld::Commands::Container::Start', Class.new)
    end

    [true, false].each do |consistent|
      it "does not mutate a config-error clone source with consistent=#{consistent}" do
        ct = build_send_ct(
          config_state: :error,
          config_state_error: {
            source: 'lxc_config',
            message: 'rootfs path is not available'
          }
        )
        command = described_class.new(
          {
            id: 'ct1',
            pool: 'tank',
            clone: true,
            consistent:,
            restart: true,
            start: false
          },
          {}
        )

        allow(OsCtld::DB::Containers).to receive(:find)
          .with('ct1', 'tank')
          .and_return(ct)
        allow(command).to receive(:call_cmd!)
        allow(command).to receive(:send_dataset)
        allow(command).to receive(:zfs)

        expect do
          command.execute
        end.to raise_error(
          OsCtld::CommandFailed,
          'container configuration is not ready (state: error): rootfs path is not available'
        )
        expect(command).not_to have_received(:call_cmd!)
        expect(command).not_to have_received(:send_dataset)
        expect(command).not_to have_received(:zfs)
        expect(ct.send_log.state_running).to be_nil
        expect(ct.save_config_calls).to eq(0)
      end
    end

    it 'keeps the transfer open when stopping the source container fails' do
      ct = build_send_ct
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: true,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'stop failed')
      allow(command).to receive(:send_dataset)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'stop failed')

      expect(command).not_to have_received(:send_dataset)
      expect(ct.closed_send_log).to be(false)
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to be_nil
      expect(ct.send_log.state_running).to be(true)
    end

    it 'does not stop a healthy replacement when a residual already exists' do
      active_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      residual_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      residual = { 'id' => residual_id.dump, 'role' => 'residual' }
      lifecycle = build_lifecycle(
        [
          { 'id' => active_id.dump, 'role' => 'active' },
          residual
        ],
        residuals: [residual]
      )
      ct = build_send_ct(lifecycle:)
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: true,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs)

      expect do
        command.execute
      end.to raise_error(
        OsCtld::CommandFailed,
        /consistent container send is blocked.*residual/
      )
      expect(command).not_to have_received(:call_cmd!)
      expect(command).not_to have_received(:send_dataset)
      expect(command).not_to have_received(:zfs)
    end

    it 'does not snapshot when stopping quarantines a residual' do
      run_id = OsCtld::Container::RunId.new(
        pool_name: 'tank',
        container_id: 'ct1'
      )
      lifecycle = build_lifecycle(
        [{ 'id' => run_id.dump, 'role' => 'residual' }]
      )
      ct = build_send_ct(lifecycle:)
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: true,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(
          status: true,
          output: { lifecycle_state: 'quarantined' }
        )
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs)

      expect do
        command.execute
      end.to raise_error(
        OsCtld::CommandFailed,
        /consistent container send is blocked.*residual/
      )
      expect(command).not_to have_received(:send_dataset)
      expect(command).not_to have_received(:zfs)
    end

    it 'keeps a retryable cutover snapshot when restarting the source container fails' do
      ct = build_send_ct
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: true,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Start, id: 'ct1', pool: 'tank')
        .and_raise(OsCtld::CommandFailed, 'start failed')
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs)

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'start failed')

      expect(command).not_to have_received(:send_dataset)
      expect(ct.closed_send_log).to be(false)
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to match(/^osctl-send-incr-/)
      expect(ct.send_log.state_running).to be(true)
    end

    it 'keeps the cutover retryable when the target handoff fails' do
      ct = build_send_ct
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: false,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )
      ssh_calls = stub_send_ssh(
        command,
        transfer_success: false
      )
      zfs_calls = []

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs) do |op, _flag, target|
        zfs_calls << [op, target]
      end

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'transfer failed')

      snap = zfs_calls.detect { |op, _target| op == :snapshot }[1].split('@', 2).last
      destroy_calls = zfs_calls.filter_map do |op, target|
        target if op == :destroy
      end

      expect(ssh_calls).to eq([%w[receive transfer token-1]])
      expect(command).to have_received(:send_dataset).with(ct, ct.dataset, snap)
      expect(destroy_calls).to be_empty
      expect(ct.closed_send_log).to be(false)
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to eq(snap)
      expect(ct.send_log.state_running).to be(true)
    end

    it 'keeps the cutover retryable when the final sync fails' do
      ct = build_send_ct
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: false,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )
      zfs_calls = []

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
        .and_raise(OsCtld::CommandFailed, 'sync failed')
      allow(command).to receive(:zfs) do |op, _flag, target|
        zfs_calls << [op, target]
      end

      expect do
        command.execute
      end.to raise_error(OsCtld::CommandFailed, 'sync failed')

      snap = zfs_calls.detect { |op, _target| op == :snapshot }[1].split('@', 2).last

      expect(command).to have_received(:send_dataset).with(ct, ct.dataset, snap)
      expect(ct.closed_send_log).to be(false)
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to eq(snap)
      expect(ct.send_log.state).to eq(:base)
      expect(ct.send_log.state_running).to be(true)
    end

    it 'drops the failed cutover snapshot before retrying' do
      ct = build_send_ct(state_snapshot: 'snap-failed')
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: false,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )
      ssh_calls = stub_send_ssh(
        command,
        transfer_success: true
      )
      zfs_calls = []

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs) do |op, _flag, target|
        zfs_calls << [op, target]
      end

      expect(command.execute).to eq(status: true, output: nil)

      destroy_calls = zfs_calls.filter_map { |op, target| target if op == :destroy }
      snapshot_call = zfs_calls.detect do |op, target|
        op == :snapshot && target.start_with?('tank/ct1@')
      end
      snap = snapshot_call[1].split('@', 2).last

      expect(ssh_calls).to eq([%w[receive transfer token-1]])
      expect(destroy_calls).to include('tank/ct1@snap-failed')
      expect(ct.send_log.snapshots).to eq(['snap-base'])
      expect(ct.send_log.state_snapshot).to eq(snap)
      expect(ct.send_log.state).to eq(:transfer)
      expect(ct.send_log.state_running).to be(true)
    end

    it 'retries the target handoff with start again when requested' do
      ct = build_send_ct(
        runtime_state: :stopped,
        state_snapshot: 'snap-failed',
        state_running: true
      )
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: false,
          consistent: true,
          restart: true,
          start: true
        },
        {}
      )
      ssh_calls = stub_send_ssh(
        command,
        transfer_success: true
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs)

      expect(command.execute).to eq(status: true, output: nil)

      expect(ssh_calls).to eq([%w[receive transfer token-1 start]])
      expect(ct.send_log.state_running).to be(true)
    end

    it 'restarts the source on clone retry when the original cutover stopped it' do
      ct = build_send_ct(
        runtime_state: :stopped,
        state_snapshot: 'snap-failed',
        state_running: true
      )
      command = described_class.new(
        {
          id: 'ct1',
          pool: 'tank',
          clone: true,
          consistent: true,
          restart: true,
          start: false
        },
        {}
      )

      allow(OsCtld::DB::Containers).to receive(:find)
        .with('ct1', 'tank')
        .and_return(ct)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Stop, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:call_cmd!)
        .with(OsCtld::Commands::Container::Start, id: 'ct1', pool: 'tank')
        .and_return(status: true, output: nil)
      allow(command).to receive(:send_dataset)
      allow(command).to receive(:zfs)
      stub_send_ssh(command, transfer_success: true)

      expect(command.execute).to eq(status: true, output: nil)

      expect(command).to have_received(:call_cmd!)
        .with(OsCtld::Commands::Container::Start, id: 'ct1', pool: 'tank')
    end
  end
end

# rubocop:enable RSpec/DescribeClass

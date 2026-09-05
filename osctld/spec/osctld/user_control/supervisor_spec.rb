# frozen_string_literal: true

require 'osctld/user_control/command'
require 'osctld/user_control/supervisor'

RSpec.describe OsCtld::UserControl::Supervisor do
  def build_service_pair
    server_class = Class.new do
      def stop; end
    end

    [
      instance_double(server_class, stop: nil),
      instance_double(Thread, join: nil)
    ]
  end

  subject(:supervisor) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set('@mutex', Mutex.new)
      instance.instance_variable_set('@servers', servers)
    end
  end

  let(:namespaced_server) { build_service_pair }
  let(:user_server) { build_service_pair }
  let(:servers) do
    {
      namespaced: namespaced_server,
      'tank:alice' => user_server
    }
  end

  describe '#stop_all' do
    it 'stops and joins each server exactly once' do
      supervisor.stop_all

      expect(namespaced_server[0]).to have_received(:stop).once
      expect(namespaced_server[1]).to have_received(:join).once
      expect(user_server[0]).to have_received(:stop).once
      expect(user_server[1]).to have_received(:join).once
    end

    it 'stays safe when only the namespaced server exists' do
      supervisor.instance_variable_set('@servers', { namespaced: namespaced_server })

      expect { supervisor.stop_all }.not_to raise_error
      expect(namespaced_server[0]).to have_received(:stop).once
      expect(namespaced_server[1]).to have_received(:join).once
    end
  end

  describe '#start_server' do
    let(:user_class) do
      Struct.new(:name, :ugid, :pool, keyword_init: true) do
        def ident = "#{pool}:#{name}"
      end
    end
    let(:user) { user_class.new(name: 'alice', ugid: 12_345, pool: 'tank') }

    it 'creates, chmods, and stores a user control socket server' do
      socket = instance_double(UNIXServer)
      generic_server_class = Class.new do
        def initialize(*); end
      end
      generic_server = instance_double(generic_server_class)
      thread = instance_double(Thread)

      stub_const('OsCtld::RunState::USER_CONTROL_DIR', '/run/osctl/user-control')
      stub_const('OsCtld::Generic::Server', generic_server_class)
      allow(UNIXServer).to receive(:new).with('/run/osctl/user-control/12345.sock').and_return(socket)
      allow(File).to receive(:chown)
      allow(File).to receive(:chmod)
      allow(OsCtld::Generic::Server).to receive(:new).and_return(generic_server)
      allow(Thread).to receive(:new).and_return(thread)

      supervisor.start_server(user)

      expect(File).to have_received(:chown).with(0, 12_345, '/run/osctl/user-control/12345.sock')
      expect(File).to have_received(:chmod).with(0o660, '/run/osctl/user-control/12345.sock')
      expect(OsCtld::Generic::Server).to have_received(:new).with(
        socket,
        described_class::ClientHandler,
        opts: { user: },
        thread_group: :user_control
      )
      expect(supervisor.instance_variable_get('@servers')['tank:alice']).to eq([generic_server, thread])
    end
  end

  describe '#start_namespaced' do
    it 'creates the namespaced socket server in the user-control thread group' do
      socket = instance_double(UNIXServer)
      generic_server_class = Class.new do
        def initialize(*); end
      end
      generic_server = instance_double(generic_server_class)
      thread = instance_double(Thread)

      stub_const('OsCtld::RunState::USER_CONTROL_DIR', '/run/osctl/user-control')
      stub_const('OsCtld::Generic::Server', generic_server_class)
      allow(UNIXServer).to receive(:new).with('/run/osctl/user-control/namespaced.sock').and_return(socket)
      allow(File).to receive(:chown)
      allow(File).to receive(:chmod)
      allow(OsCtld::Generic::Server).to receive(:new).and_return(generic_server)
      allow(Thread).to receive(:new).and_return(thread)

      supervisor.send(:start_namespaced)

      expect(File).to have_received(:chown).with(0, 0, '/run/osctl/user-control/namespaced.sock')
      expect(File).to have_received(:chmod).with(0o666, '/run/osctl/user-control/namespaced.sock')
      expect(OsCtld::Generic::Server).to have_received(:new).with(
        socket,
        described_class::NamespacedClientHandler,
        thread_group: :user_control
      )
      expect(supervisor.instance_variable_get('@servers')[:namespaced]).to eq([generic_server, thread])
    end
  end

  describe '#stop_server' do
    let(:user_class) do
      Struct.new(:name, :ugid, :pool, keyword_init: true) do
        def ident = "#{pool}:#{name}"
      end
    end
    let(:user) { user_class.new(name: 'alice', ugid: 12_345, pool: 'tank') }

    it 'stops, joins, and unlinks the user control socket' do
      server = build_service_pair

      stub_const('OsCtld::RunState::USER_CONTROL_DIR', '/run/osctl/user-control')
      supervisor.instance_variable_set('@servers', { 'tank:alice' => server })
      allow(File).to receive(:unlink)

      supervisor.stop_server(user)

      expect(server[0]).to have_received(:stop).once
      expect(server[1]).to have_received(:join).once
      expect(File).to have_received(:unlink).with('/run/osctl/user-control/12345.sock')
    end

    it 'distinguishes users with the same name on different pools' do
      tank_server = build_service_pair
      dozer_server = build_service_pair
      dozer_user = user_class.new(name: 'alice', ugid: 54_321, pool: 'dozer')

      stub_const('OsCtld::RunState::USER_CONTROL_DIR', '/run/osctl/user-control')
      supervisor.instance_variable_set(
        '@servers',
        {
          'tank:alice' => tank_server,
          dozer_user.ident => dozer_server
        }
      )
      allow(File).to receive(:unlink)

      supervisor.stop_server(user)

      expect(tank_server[0]).to have_received(:stop).once
      expect(tank_server[1]).to have_received(:join).once
      expect(dozer_server[0]).not_to have_received(:stop)
      expect(dozer_server[1]).not_to have_received(:join)
      expect(File).to have_received(:unlink).with('/run/osctl/user-control/12345.sock')
      expect(File).not_to have_received(:unlink).with('/run/osctl/user-control/54321.sock')
      expect(supervisor.instance_variable_get('@servers')).to include(
        'dozer:alice' => dozer_server
      )
    end
  end

  describe described_class::NamespacedClientHandler do
    subject(:handler) { described_class.new(Object.new, {}) }

    it 'rejects non-hash input' do
      expect(handler.handle_cmd('bad')).to eq(status: false, message: 'invalid input')
    end

    it 'rejects unsupported commands before inspecting peer credentials' do
      expect(handler.handle_cmd(cmd: 'ct_start', opts: {})).to eq(
        status: false,
        message: 'invalid cmd'
      )
    end
  end

  # rubocop:disable RSpec/MultipleMemoizedHelpers, RSpec/SubjectStub
  # rubocop:disable RSpec/VerifiedDoubleReference
  describe described_class::ClientHandler do
    subject(:handler) { described_class.new(socket, user:) }

    let(:socket) do
      instance_double(
        UNIXSocket,
        getsockopt: [321, 12_345, 12_345].pack('LLL')
      )
    end
    let(:user) { instance_double('User', ugid: 12_345, ident: 'tank:alice') }
    let(:peer) { instance_double(OsCtld::ProcessIdentity, pid: 321, close: nil) }
    let(:command) { class_double('OsCtld::UserControl::Commands::CtPreStart') }

    before do
      allow(OsCtld::ProcessIdentity).to receive(:new)
        .with(321, namespaces: [], root: false)
        .and_return(peer)
      allow(OsCtld::UserControl::Command).to receive(:find)
        .with(:ct_pre_start)
        .and_return(command)
      allow(command).to receive(:run).and_return(status: true, output: nil)
    end

    it 'uses kernel peer credentials and passes an internal process identity' do
      ret = handler.handle_cmd(
        cmd: 'ct_pre_start',
        opts: { id: 'ct1', pool: 'tank', run_id: 'current' }
      )

      expect(ret).to eq(status: true, output: nil)
      expect(command).to have_received(:run).with(
        user,
        { id: 'ct1', pool: 'tank', run_id: 'current' },
        peer:
      )
    end

    it 'does not expose namespaced-only commands on the per-user socket' do
      expect(
        handler.handle_cmd(cmd: 'ct_post_mount', opts: {})
      ).to eq(status: false, message: 'invalid cmd')
    end
  end

  describe 'authenticated namespaced dispatch' do
    subject(:handler) { described_class::NamespacedClientHandler.new(socket, {}) }

    let(:socket) do
      instance_double(
        UNIXSocket,
        getsockopt: [654, 100_000, 100_000].pack('LLL'),
        puts: nil
      )
    end
    let(:id_map) { instance_double('IdMap', ns_to_host: 100_000) }
    let(:user) do
      instance_double(
        'User',
        ident: 'tank:alice',
        uid_map: id_map,
        gid_map: id_map
      )
    end
    let(:ct) do
      instance_double(
        'Container',
        user:,
        ident: 'tank:ct1',
        base_cgroup_path: '/osctl/pool.tank/ct.ct1'
      )
    end
    let(:peer) do
      instance_double(
        OsCtld::ProcessIdentity,
        pid: 654,
        in_cgroup_subtree?: true,
        close: nil
      )
    end
    let(:command) { class_double('OsCtld::UserControl::Commands::CtPreMount') }

    before do
      stub_const('OsCtld::DB::Containers', double)
      allow(handler).to receive(:log)
      allow(OsCtld::DB::Containers).to receive(:find).with('ct1', 'tank').and_return(ct)
      allow(OsCtld::ProcessIdentity).to receive(:new)
        .with(654, namespaces: %i[mnt user], root: true)
        .and_return(peer)
      allow(OsCtld::UserControl::Command).to receive(:find)
        .with(:ct_pre_mount)
        .and_return(command)
      allow(command).to receive(:run).and_return(status: true, output: nil)
    end

    it 'binds a namespaced callback to the requested container cgroup' do
      ret = handler.handle_cmd(
        cmd: 'ct_pre_mount',
        opts: { id: 'ct1', pool: 'tank', run_id: 'current' }
      )

      expect(ret).to eq(status: true, output: nil)
      expect(peer).to have_received(:in_cgroup_subtree?).with(
        '/osctl/pool.tank/ct.ct1'
      )
      expect(command).to have_received(:run).with(
        user,
        { id: 'ct1', pool: 'tank', run_id: 'current' },
        peer:
      )
    end

    it 'receives the mounted rootfs descriptor for post-mount dispatch' do
      rootfs_dir = instance_double(IO, closed?: false, close: nil)
      allow(socket).to receive(:wait_readable)
        .with(described_class::NamespacedClientHandler::ROOTFS_DESCRIPTOR_TIMEOUT)
        .and_return(true)
      allow(socket).to receive(:recv_io).and_return(rootfs_dir)
      allow(OsCtld::UserControl::Command).to receive(:find)
        .with(:ct_post_mount)
        .and_return(command)

      ret = handler.handle_cmd(
        cmd: 'ct_post_mount',
        opts: { id: 'ct1', pool: 'tank', run_id: 'current' }
      )

      expect(ret).to eq(status: true, output: nil)
      expect(socket).to have_received(:puts).with({
        status: true,
        progress: described_class::NamespacedClientHandler::ROOTFS_DESCRIPTOR_REQUEST
      }.to_json)
      expect(command).to have_received(:run).with(
        user,
        {
          id: 'ct1',
          pool: 'tank',
          run_id: 'current',
          rootfs_dir:
        },
        peer:
      )
      expect(rootfs_dir).to have_received(:close)
    end

    it 'rejects a sibling-container peer before dispatch' do
      allow(peer).to receive(:in_cgroup_subtree?).and_return(false)

      expect(
        handler.handle_cmd(
          cmd: 'ct_pre_mount',
          opts: { id: 'ct1', pool: 'tank', run_id: 'current' }
        )
      ).to eq(status: false, message: 'invalid container')
      expect(command).not_to have_received(:run)
    end
  end
  # rubocop:enable RSpec/MultipleMemoizedHelpers, RSpec/SubjectStub
  # rubocop:enable RSpec/VerifiedDoubleReference
end

# frozen_string_literal: true

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
      expect(supervisor.instance_variable_get('@servers')['tank:alice']).to eq([generic_server, thread])
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
end

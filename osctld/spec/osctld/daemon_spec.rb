# frozen_string_literal: true

require 'osctld/daemon'
require 'osctld/command'

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
      allow(daemon).to receive(:log)
      allow(daemon).to receive(:exit).with(false).and_raise(SystemExit)
      allow(FileUtils).to receive(:rm_f)
      allow(OsCtld::UserControl).to receive(:stop)
      allow(OsCtld::SendReceive).to receive(:stop)
      allow(OsCtld::DB::Repositories).to receive(:each).and_yield(repo)
      allow(OsCtld::DB::Pools).to receive(:get).and_return([pool])
      allow(OsCtld::ThreadReaper).to receive(:stop)
      allow(OsCtld::Eventd).to receive(:shutdown)
      allow(OsCtld::CpuScheduler).to receive(:shutdown)
      allow(OsCtld::Monitor::Master).to receive(:stop)
      allow(OsCtld::LockRegistry).to receive(:stop)

      expect { daemon.stop }.to raise_error(SystemExit)

      expect(server).to have_received(:stop).ordered
      expect(OsCtld::ThreadReaper).to have_received(:stop).ordered
      expect(OsCtld::Eventd).to have_received(:shutdown).ordered
      expect(OsCtld::UserControl).to have_received(:stop).ordered
      expect(OsCtld::SendReceive).to have_received(:stop).ordered
      expect(repo).to have_received(:stop).ordered
      expect(pool).to have_received(:stop).ordered
      expect(OsCtld::CpuScheduler).to have_received(:shutdown).ordered
      expect(OsCtld::Monitor::Master).to have_received(:stop).ordered
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

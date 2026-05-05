# frozen_string_literal: true

require 'osctld/daemon'

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

  describe OsCtld::Daemon::ClientHandler do
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
  end
end

# frozen_string_literal: true

require 'osctld/send_receive/server'

RSpec.describe OsCtld::SendReceive::Server do
  subject(:server) { fresh_singleton(described_class) }

  before do
    stub_const('OsCtld::SendReceive::SOCKET', '/run/osctl/send-receive/control.sock')
    stub_const('OsCtld::SendReceive::UID', 23_456)
    stub_const('OsCtld::Generic::Server', Class.new do
      def initialize(*); end

      def start; end

      def stop; end
    end)
  end

  it 'starts the control socket server with the expected permissions' do
    socket = instance_double(UNIXServer)
    generic_server = instance_double(OsCtld::Generic::Server, start: nil)
    thread = instance_double(Thread)

    allow(UNIXServer).to receive(:new).with(OsCtld::SendReceive::SOCKET).and_return(socket)
    allow(File).to receive(:chown)
    allow(File).to receive(:chmod)
    allow(OsCtld::Generic::Server).to receive(:new).with(
      socket,
      described_class::ClientHandler
    ).and_return(generic_server)
    allow(Thread).to receive(:new).and_yield.and_return(thread)

    server.start

    expect(File).to have_received(:chown).with(23_456, 0, OsCtld::SendReceive::SOCKET)
    expect(File).to have_received(:chmod).with(0o600, OsCtld::SendReceive::SOCKET)
    expect(OsCtld::Generic::Server).to have_received(:new).once
  end

  it 'stops the server thread and removes the control socket' do
    generic_server = instance_double(OsCtld::Generic::Server, stop: nil)
    thread = instance_double(Thread, join: nil)

    server.instance_variable_set('@server', generic_server)
    server.instance_variable_set('@thread', thread)
    allow(File).to receive(:unlink)

    server.stop

    expect(generic_server).to have_received(:stop).once
    expect(thread).to have_received(:join).once
    expect(File).to have_received(:unlink).with(OsCtld::SendReceive::SOCKET)
  end

  it 'dispatches client requests through SendReceive::Command' do
    socket = Object.new
    handler = described_class::ClientHandler.new(socket, {})
    cmd_class = Class.new do
      def self.run(**); end
    end

    stub_const('OsCtld::SendReceive::Command', Class.new do
      def self.find(_name); end
    end)
    allow(OsCtld::SendReceive::Command).to receive(:find).with(:receive_base).and_return(cmd_class)
    allow(cmd_class).to receive(:run).and_return(status: true, output: 'ok')

    expect(
      handler.handle_cmd(cmd: 'receive_base', opts: { token: 'abc' })
    ).to eq(status: true, output: 'ok')
    expect(cmd_class).to have_received(:run).with(
      internal: { handler: handler },
      token: 'abc'
    )
  end
end

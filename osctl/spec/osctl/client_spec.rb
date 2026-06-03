# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Client do
  def build_client(socket = nil)
    described_class.new.tap do |client|
      client.instance_variable_set(:@sock, socket) if socket
    end
  end

  it 'opens the socket and reads the greeting version' do
    socket = FakeSocketHelpers::LineSocketDouble.new(["{\"version\":\"24.11\"}\n"])
    allow(UNIXSocket).to receive(:new).with(described_class::SOCKET).and_return(socket)

    client = described_class.new
    client.open

    expect(client.version).to eq('24.11')
  end

  it 'json-encodes commands sent to the socket' do
    socket = FakeSocketHelpers::LineSocketDouble.new
    client = build_client(socket)

    client.cmd(:ct_list, pool: 'tank')

    payload = JSON.parse(socket.written_lines.last)
    expect(payload).to eq(
      'cmd' => 'ct_list',
      'opts' => { 'pool' => 'tank' }
    )
  end

  it 'forwards file descriptors with send_io' do
    socket = FakeSocketHelpers::LineSocketDouble.new
    client = build_client(socket)
    io = StringIO.new

    client.send_io(io)

    expect(socket.sent_ios).to eq([io])
  end

  it 'receives all newline-terminated messages from a single socket read' do
    socket = FakeSocketHelpers::LineSocketDouble.new(["{\"status\":true}\n{\"status\":false}\n"])
    client = build_client(socket)

    expect(client.receive).to eq(
      ['{"status":true}', '{"status":false}']
    )
  end

  it 'raises when the daemon closes the socket mid-read' do
    socket = FakeSocketHelpers::LineSocketDouble.new([''])
    client = build_client(socket)

    expect { client.receive }.to raise_error(OsCtl::Client::Error, 'osctld closed connection')
  end

  it 'raises when the daemon closes the socket with nil EOF' do
    socket = instance_double(UNIXSocket, recv: nil)
    client = build_client(socket)

    expect { client.receive }.to raise_error(OsCtl::Client::Error, 'osctld closed connection')
  end

  it 'raises when the daemon resets the socket' do
    socket = instance_double(UNIXSocket)
    allow(socket).to receive(:recv).and_raise(Errno::ECONNRESET)
    client = build_client(socket)

    expect { client.receive }.to raise_error(OsCtl::Client::Error, 'osctld closed connection')
  end

  it 'raises from response wait when the daemon closes after progress' do
    socket = instance_double(UNIXSocket)
    allow(socket).to receive(:recv).and_return(
      "{\"status\":true,\"progress\":\"step 1\"}\n",
      nil
    )
    client = build_client(socket)
    progress = []

    expect do
      client.receive_resp { |msg| progress << msg }
    end.to raise_error(OsCtl::Client::Error, 'osctld closed connection')

    expect(progress).to eq(['step 1'])
  end

  it 'handles progress updates and buffers extra responses across calls' do
    socket = FakeSocketHelpers::LineSocketDouble.new(
      [
        <<~RESPONSES
          {"status":true,"progress":"step 1"}
          {"status":true,"response":{"value":1}}
          {"status":false,"message":"boom"}
        RESPONSES
      ]
    )
    client = build_client(socket)
    progress = []

    first = client.receive_resp { |msg| progress << msg }
    second = client.receive_resp

    expect(progress).to eq(['step 1'])
    expect(first.data).to eq(value: 1)
    expect(second).to be_error
    expect(second.message).to eq('boom')
  end

  it 'raises from response! when the final response is an error' do
    socket = FakeSocketHelpers::LineSocketDouble.new(["{\"status\":false,\"message\":\"invalid\"}\n"])
    client = build_client(socket)

    expect { client.response! }.to raise_error(OsCtl::Client::Error, 'invalid')
  end

  it 'returns response data from data!' do
    client = build_client
    allow(client).to receive(:receive_resp).and_return(
      client_response(status: true, response: { answer: 42 })
    )

    expect(client.data!).to eq(answer: 42)
  end

  it 'returns response data from cmd_data! after a successful command' do
    socket = FakeSocketHelpers::LineSocketDouble.new(["{\"status\":true,\"response\":{\"id\":\"ct1\"}}\n"])
    client = build_client(socket)

    expect(client.cmd_data!(:ct_show, id: 'ct1')).to eq(id: 'ct1')

    payload = JSON.parse(socket.written_lines.last)
    expect(payload).to eq(
      'cmd' => 'ct_show',
      'opts' => { 'id' => 'ct1' }
    )
  end

  it 'passes buffered progress updates through cmd_response!' do
    socket = FakeSocketHelpers::LineSocketDouble.new(
      [
        <<~RESPONSES
          {"status":true,"progress":"syncing"}
          {"status":true,"response":{"status":"ok"}}
        RESPONSES
      ]
    )
    client = build_client(socket)
    progress = []

    resp = client.cmd_response!(:ct_send_sync, id: 'ct1') { |msg| progress << msg }

    expect(progress).to eq(['syncing'])
    expect(resp.data).to eq(status: 'ok')
  end
end

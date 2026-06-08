# frozen_string_literal: true

require 'osctld/generic/server'

RSpec.describe OsCtld::Generic::Server do
  it 'spawns a handler thread for accepted clients and registers it with ThreadReaper' do
    server_socket_class = Class.new do
      def accept; end

      def close; end
    end
    client_socket_class = Class.new
    handler_instance_class = Class.new do
      def communicate; end
    end
    handler_class = stub_const('SpecHandler', Class.new do
      def initialize(_socket, _opts); end
    end)
    server_socket = instance_double(server_socket_class)
    client_socket = instance_double(client_socket_class)
    handler_instance = instance_double(handler_instance_class, communicate: nil)
    thread = instance_double(Thread)

    accept_calls = 0

    allow(server_socket).to receive(:accept) do
      accept_calls += 1
      raise IOError unless accept_calls == 1

      client_socket
    end
    allow(handler_class).to receive(:new).with(client_socket, { user: 'alice' }).and_return(handler_instance)
    allow(Thread).to receive(:new).and_yield.and_return(thread)
    allow(OsCtld::ThreadReaper).to receive(:add)

    described_class.new(server_socket, handler_class, opts: { user: 'alice' }).start

    expect(OsCtld::ThreadReaper).to have_received(:add).with(
      thread,
      handler_instance,
      group: OsCtld::ThreadReaper::DEFAULT_GROUP
    )
  end

  it 'registers client threads in the configured reaper group' do
    server_socket_class = Class.new do
      def accept; end

      def close; end
    end
    client_socket_class = Class.new
    handler_instance_class = Class.new do
      def communicate; end
    end
    handler_class = stub_const('GroupedSpecHandler', Class.new do
      def initialize(_socket, _opts); end
    end)
    server_socket = instance_double(server_socket_class)
    client_socket = instance_double(client_socket_class)
    handler_instance = instance_double(handler_instance_class, communicate: nil)
    thread = instance_double(Thread)

    accept_calls = 0

    allow(server_socket).to receive(:accept) do
      accept_calls += 1
      raise IOError unless accept_calls == 1

      client_socket
    end
    allow(handler_class).to receive(:new).with(client_socket, {}).and_return(handler_instance)
    allow(Thread).to receive(:new).and_yield.and_return(thread)
    allow(OsCtld::ThreadReaper).to receive(:add)

    described_class.new(server_socket, handler_class, thread_group: :user_control).start

    expect(OsCtld::ThreadReaper).to have_received(:add).with(
      thread,
      handler_instance,
      group: :user_control
    )
  end

  it 'closes the listening socket when stopped' do
    server_socket_class = Class.new do
      def close; end
    end
    server_socket = instance_double(server_socket_class, close: nil)

    described_class.new(server_socket, Class.new).stop

    expect(server_socket).to have_received(:close)
  end
end

# frozen_string_literal: true

require 'osctld/exceptions'
require 'osctld/generic/client_handler'

RSpec.describe OsCtld::Generic::ClientHandler do
  def write_json_line(io, data)
    io.write("#{data.to_json}\n")
  end

  let(:handler_class) do
    Class.new(described_class) do
      class << self
        attr_accessor :seen_requests
      end

      def server_version
        opts[:version]
      end

      def handle_cmd(req)
        self.class.seen_requests ||= []
        self.class.seen_requests << req

        case req[:cmd]
        when 'ping'
          ok('pong')
        when 'progress'
          send_update('step 1')
          ok('done')
        when 'fail'
          error!('command failed')
        when 'raise'
          raise 'boom'
        when 'handled'
          { status: :handled }
        when 'bad_return'
          :nope
        else
          error('unsupported')
        end
      end

      def log_type
        self.class.name || 'SpecClientHandler'
      end

      def log(*); end

      def denixstorify(backtrace)
        backtrace || []
      end
    end
  end

  it 'sends the server version banner before processing commands' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, version: '1.2.3')
      thread = Thread.new { handler.communicate }

      expect(read_json_line(client_sock)).to eq(version: '1.2.3')

      write_json_line(client_sock, { cmd: 'ping', opts: {} })
      expect(read_json_line(client_sock)).to eq(status: true, response: 'pong')

      client_sock.close
      join_thread!(thread)
    end
  end

  it 'returns successful command responses to the client' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, {})
      thread = Thread.new { handler.communicate }

      write_json_line(client_sock, { cmd: 'ping', opts: {} })

      expect(read_json_line(client_sock)).to eq(status: true, response: 'pong')

      client_sock.close
      join_thread!(thread)
    end
  end

  it 'streams progress updates before the final response' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, {})
      thread = Thread.new { handler.communicate }

      write_json_line(client_sock, { cmd: 'progress', opts: {} })

      expect(read_json_line(client_sock)).to eq(status: true, progress: 'step 1')
      expect(read_json_line(client_sock)).to eq(status: true, response: 'done')

      client_sock.close
      join_thread!(thread)
    end
  end

  it 'returns command failure messages to the client' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, {})
      thread = Thread.new { handler.communicate }

      write_json_line(client_sock, { cmd: 'fail', opts: {} })

      expect(read_json_line(client_sock)).to eq(status: false, message: 'command failed')

      client_sock.close
      join_thread!(thread)
    end
  end

  it 'turns unexpected exceptions into internal errors' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, {})
      thread = Thread.new { handler.communicate }

      write_json_line(client_sock, { cmd: 'raise', opts: {} })

      expect(read_json_line(client_sock)).to eq(status: false, message: 'internal error')

      client_sock.close
      join_thread!(thread)
    end
  end

  it 'turns invalid handler return values into internal errors' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, {})
      thread = Thread.new { handler.communicate }

      write_json_line(client_sock, { cmd: 'bad_return', opts: {} })

      expect(read_json_line(client_sock)).to eq(status: false, message: 'internal error')

      client_sock.close
      join_thread!(thread)
    end
  end

  it 'replies with a syntax error for malformed json' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, {})
      thread = Thread.new { handler.communicate }

      client_sock.write("{not valid json}\n")

      expect(read_json_line(client_sock)).to eq(
        status: false,
        message: 'syntax error, expected a valid JSON'
      )

      client_sock.close
      join_thread!(thread)
    end
  end

  it 'rejects json values that are not request hashes' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, {})
      thread = Thread.new { handler.communicate }

      client_sock.write("[]\n")

      expect(read_json_line(client_sock)).to eq(
        status: false,
        message: 'invalid input'
      )

      client_sock.close
      join_thread!(thread)
    end
  end

  it 'exits without a final response when the command hijacks the connection' do
    with_socket_pair do |server_sock, client_sock|
      handler = handler_class.new(server_sock, {})
      thread = Thread.new { handler.communicate }

      write_json_line(client_sock, { cmd: 'handled', opts: {} })

      join_thread!(thread)
      expect(thread).not_to be_alive
      expect { read_json_line(client_sock, timeout: 0.1) }.to raise_error(/socket read timed out/)
    end
  end
end

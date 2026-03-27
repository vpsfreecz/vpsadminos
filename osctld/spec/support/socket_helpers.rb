# frozen_string_literal: true

require 'socket'
require 'json'
require 'timeout'

module SocketHelpers
  def with_socket_pair
    sockets = Socket.pair(:UNIX, :STREAM, 0)
    yield(*sockets)
  ensure
    sockets&.each do |sock|
      sock.close unless sock.closed?
    rescue IOError
      nil
    end
  end

  def read_json_line(io, timeout: 2)
    line = Timeout.timeout(timeout) { io.gets }
    raise 'expected a JSON line from socket, got EOF' if line.nil?

    JSON.parse(line, symbolize_names: true)
  rescue Timeout::Error
    raise "socket read timed out after #{timeout}s"
  end

  def join_thread!(thread, timeout: 2)
    Timeout.timeout(timeout) { thread.join }
  rescue Timeout::Error
    raise "thread join timed out after #{timeout}s"
  end
end

RSpec.configure do |config|
  config.include SocketHelpers
end

# frozen_string_literal: true

module FakeClientHelpers
  class ClientDouble
    attr_reader :calls, :sent_ios, :socket

    def initialize(cmd_data: {}, cmd_responses: {}, responses: [], socket: nil)
      @cmd_data = normalize(cmd_data)
      @cmd_responses = normalize(cmd_responses)
      @responses = responses.dup
      @calls = []
      @sent_ios = []
      @socket = socket
      @opened = false
      @closed = false
    end

    def open
      @opened = true
    end

    def opened?
      @opened
    end

    def close
      @closed = true
      socket.close if socket && !socket.closed?
    end

    def closed?
      @closed
    end

    def cmd(cmd, **opts)
      @calls << [:cmd, cmd, opts]
      nil
    end

    def cmd_data!(cmd, **opts, &block)
      @calls << [:cmd_data!, cmd, opts]
      fetch(@cmd_data, cmd, opts, block)
    end

    def cmd_response(cmd, **opts, &block)
      @calls << [:cmd_response, cmd, opts]
      fetch(@cmd_responses, cmd, opts, block)
    end

    def cmd_response!(cmd, **, &)
      ret = cmd_response(cmd, **, &)
      raise OsCtl::Client::Error, ret.message if ret.error?

      ret
    end

    def response!
      raise 'no queued responses left' if @responses.empty?

      @responses.shift
    end

    def receive_resp
      response!
    end

    def send_io(io)
      @sent_ios << io
    end

    private

    def normalize(map)
      map.transform_values { |v| Array(v).dup }
    end

    def fetch(map, cmd, opts, progress_callback)
      queue = map.fetch(cmd) { raise "no fake response registered for #{cmd.inspect}" }
      raise "response queue for #{cmd.inspect} is empty" if queue.empty?

      entry = queue.shift
      entry = entry.call(opts, progress_callback) if entry.respond_to?(:call)
      entry
    end
  end

  def client_response(payload)
    OsCtl::Client::Response.new(payload)
  end

  def stub_osctld_client(client)
    allow(OsCtl::Client).to receive(:new).and_return(client)
  end

  def stub_osctld_clients(*clients)
    allow(OsCtl::Client).to receive(:new).and_return(*clients)
  end
end

RSpec.configure do |config|
  config.include FakeClientHelpers
end

# frozen_string_literal: true

module FakeClientHelpers
  class ClientDouble
    attr_reader :calls, :sent_ios

    def initialize(cmd_data: {}, responses: [])
      @cmd_data = cmd_data.transform_values { |v| Array(v).dup }
      @responses = responses.dup
      @calls = []
      @sent_ios = []
      @opened = false
      @closed = false
    end

    def open
      @calls << [:open]
      @opened = true
    end

    def close
      @calls << [:close]
      @closed = true
    end

    def opened? = @opened
    def closed? = @closed

    def cmd_data!(cmd, **opts)
      @calls << [:cmd_data!, cmd, opts]
      queue = @cmd_data.fetch(cmd) { raise "no fake response for #{cmd.inspect}" }
      raise "empty fake response queue for #{cmd.inspect}" if queue.empty?

      entry = queue.shift
      entry.respond_to?(:call) ? entry.call(opts) : entry
    end

    def receive_resp
      raise 'no queued responses left' if @responses.empty?

      @responses.shift
    end

    def send_io(io)
      @sent_ios << io
    end
  end

  def client_response(payload)
    OsCtl::Client::Response.new(payload)
  end

  def stub_osctld_client(client)
    allow(OsCtl::Client).to receive(:new).and_return(client)
  end
end

RSpec.configure do |config|
  config.include FakeClientHelpers
end

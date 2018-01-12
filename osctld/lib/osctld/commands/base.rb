module OsCtld
  class Commands::Base
    def self.handle(name)
      Command.register(name, self)
    end

    def self.run(opts = {}, handler = nil)
      c = new(handler, opts)
      c.execute
    end

    attr_reader :client, :opts

    def initialize(handler, opts)
      @client_handler = handler
      @client = handler && handler.socket
      @opts = opts
    end

    def execute
      raise NotImplementedError
    end

    protected
    def call_cmd(klass, opts = {})
      klass.run(opts)
    end

    def ok(resp = nil)
      {status: true, output: resp}
    end

    def handled
      {status: :handled}
    end

    def error(msg)
      {status: false, message: msg}
    end

    def progress(msg)
      return unless @client_handler
      @client_handler.send_update(msg)
    end
  end
end

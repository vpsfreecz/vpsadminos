module OsCtld
  class Commands::Base
    def self.handle(name)
      Command.register(name, self)
    end

    def self.run(opts = {})
      c = new(opts)
      c.execute
    end

    attr_reader :opts

    def initialize(opts)
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

    def error(msg)
      {status: false, message: msg}
    end
  end
end

module OsCtl::Cli
 class Command
    def self.run(klass, method)
      Proc.new do |global_opts, opts, args|
        cmd = klass.new(global_opts, opts, args)
        cmd.method(method).call
      end
    end

    attr_reader :gopts, :opts, :args

    def initialize(global_opts, opts, args)
      @gopts = global_opts
      @opts = opts
      @args = args
    end

    def osctld(cmd, opts = {})
      c = OsCtl::Client.new
      c.open
      c.cmd(cmd, opts)
      c.reply
    end

    def osctld_fmt(*args)
      ret = osctld(*args)

      if ret[:status]
        OutputFormatter.print(ret[:response]) if ret[:response]

      else
        puts "Error occurred: #{ret[:message]}"
      end
    end
  end
end

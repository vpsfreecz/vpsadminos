module OsCtl::Cli
 class Command
    include OsCtl::Utils::Humanize

    def self.run(klass, method)
      Proc.new do |global_opts, opts, args|
        cmd = klass.new(global_opts, opts, args)

        begin
          cmd.method(method).call

        rescue OsCtl::Client::Error => e
          warn "Error occurred: #{e.message}"
          exit(false)
        end
      end
    end

    attr_reader :gopts, :opts, :args

    def initialize(global_opts, opts, args)
      @gopts = global_opts
      @opts = opts
      @args = args
    end

    def osctld_open
      c = OsCtl::Client.new
      c.open
      c
    end

    def osctld_call(cmd, opts = {})
      c = osctld_open
      c.cmd_data!(cmd, opts)
    end

    def osctld_resp(cmd, opts = {})
      c = osctld_open
      c.cmd_response(cmd, opts)
    end

    def osctld_fmt(cmd, opts = {}, cols = nil, fmt_opts = {})
      ret = osctld_call(cmd, opts)
      OutputFormatter.print(ret, cols, fmt_opts) if ret
      ret
    end
  end
end

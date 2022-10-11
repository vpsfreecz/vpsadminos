require 'json'
require 'libosctl'

module OsCtl::Cli
  class Command < OsCtl::Lib::Cli::Command
    include OsCtl::Lib::Utils::Humanize

    def self.run(klass, method, method_args = [])
      Proc.new do |global_opts, opts, args|
        OsCtl::Lib::Logger.setup(:none)

        cmd = klass.new(global_opts, opts, args)
        cmd.method(method).call(*method_args)
      end
    end

    def osctld_open
      c = OsCtl::Client.new
      c.open
      c
    end

    def osctld_call(cmd, **opts, &block)
      c = osctld_open
      opts[:cli] ||= cli_opt
      ret = c.cmd_data!(cmd, **opts, &block)
      c.close
      ret
    end

    def osctld_resp(cmd, **opts, &block)
      c = osctld_open
      opts[:cli] ||= cli_opt
      ret = c.cmd_response(cmd, **opts, &block)
      c.close
      ret
    end

    def osctld_fmt(cmd, cmd_opts: {}, fmt_opts: {}, &block)
      cmd_opts[:cli] ||= cli_opt

      if block
        ret = osctld_call(cmd, **cmd_opts, &block)
      else
        ret = osctld_call(cmd, **cmd_opts) { |msg| puts msg unless gopts[:quiet] }
      end

      if ret.is_a?(String)
        puts ret
      elsif ret
        format_output(ret, **fmt_opts)
      end

      ret
    end

    def format_output(data, **fmt_opts)
      if gopts[:json]
        puts data.to_json

      else
        OsCtl::Lib::Cli::OutputFormatter.print(data, **fmt_opts)
      end
    end

    protected
    def cli_opt
      "#{File.basename($0)} #{ARGV.join(' ')}"
    end
  end
end

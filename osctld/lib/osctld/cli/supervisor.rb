require 'optparse'

module OsCtld
  class Cli::Supervisor
    Options = Struct.new(:supervisor, :log)

    def self.run
      s = new
      s.parse

      return Cli::Daemon.run(s.opts) unless s.supervise?

      s.supervise
    end

    attr_reader :opts

    def parse
      @opts = Options.new(true, :stdout)

      OptionParser.new do |opts|
        opts.on('--[no-]supervisor', 'Toggle osctld supervisor process (enabled by default)') do |v|
          @opts.supervisor = v
        end

        opts.on('-l', '--log LOGGER', %w(syslog stdout)) do |v|
          @opts.log = v.to_sym
        end

        opts.on('-h', '--help', 'Prints help message and exit') do
          puts opts
          exit
        end
      end.parse!

      @opts
    end

    def supervise?
      opts.supervisor
    end

    def supervise
      Process.setproctitle('osctld: supervisor')
      Logger.setup(opts.log)

      out_r, out_w = IO.pipe

      pid = Process.fork do
        out_r.close

        STDIN.close
        STDOUT.reopen(out_w)
        STDERR.reopen(out_w)

        Process.exec(
          File.expand_path($0),
          '--no-supervisor',
          '--log', opts.log.to_s
        )
      end

      out_w.close

      Signal.trap('CHLD') do
        out_r.close
      end

      %w(INT TERM HUP).each do |sig|
        Signal.trap(sig) do
          Process.kill(sig, pid)
          sleep(1)
          cleanup
          exit
        end
      end

      begin
        out_r.each_line do |line|
          Logger.log(:unknown, line)
        end

      rescue IOError
        # pass
      ensure
        _, status = Process.wait2(pid)
        cleanup

        exit(status.exitstatus || 0)
      end
    end

    def cleanup
      path = '/run/osctl/osctld.sock'
      File.unlink(path) if File.exist?(path)

      Dir.glob('/run/osctl/user-control/*.sock').each { |f| File.unlink(f) }
    end
  end
end

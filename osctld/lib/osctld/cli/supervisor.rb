require 'optparse'

module OsCtld
  class Cli::Supervisor
    Options = Struct.new(:supervisor, :config, :log, :log_facility)

    def self.run
      s = new
      s.parse

      return Cli::Daemon.run(s.opts) unless s.supervise?

      s.supervise
    end

    attr_reader :opts

    def parse
      @opts = Options.new(true, nil, :stdout, 'daemon')

      OptionParser.new do |opts|
        opts.on('--[no-]supervisor', 'Toggle osctld supervisor process (enabled by default)') do |v|
          @opts.supervisor = v
        end

        opts.on('-c', '--config FILE', 'Config file') do |v|
          @opts.config = v
        end

        opts.on('-l', '--log LOGGER', %w(syslog stdout)) do |v|
          @opts.log = v.to_sym
        end

        opts.on(
          '--log-facility FACILITY',
          'Syslog facility, see man syslog(3), lowercase without LOG_ prefix'
        ) do |v|
          @opts.log_facility = v
        end

        opts.on('-h', '--help', 'Prints help message and exit') do
          puts opts
          exit
        end
      end.parse!

      if @opts.config.nil?
        warn "Provide option --config FILE"
        warn opts
        exit(false)
      end

      @opts
    end

    def supervise?
      opts.supervisor
    end

    def supervise
      Process.setproctitle('osctld: supervisor')
      OsCtl::Lib::Logger.setup(opts.log, facility: opts.log_facility)

      out_r, out_w = IO.pipe

      pid = Process.fork do
        out_r.close

        STDIN.close
        STDOUT.reopen(out_w)
        STDERR.reopen(out_w)

        Process.exec(
          File.expand_path($0),
          '--no-supervisor',
          '--config', opts.config,
          '--log', opts.log.to_s,
          '--log-facility', opts.log_facility,
          pgroup: true
        )
      end

      out_w.close

      Signal.trap('CHLD') do
        out_r.close
      end

      %w(INT TERM HUP).each do |sig|
        Signal.trap(sig) do
          Process.kill(sig, pid)
        end
      end

      begin
        out_r.each_line do |line|
          OsCtl::Lib::Logger.log(:unknown, line)
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
      File.unlink(Daemon::SOCKET) if File.exist?(Daemon::SOCKET)

      Dir.glob(File.join(RunState::USER_CONTROL_DIR, '*.sock')).each do |f|
        File.unlink(f)
      end

      File.unlink(SendReceive::SOCKET) if File.exist?(SendReceive::SOCKET)
    end
  end
end

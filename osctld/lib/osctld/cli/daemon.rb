module OsCtld
  class Cli::Daemon
    def self.run(opts)
      d = OsCtld::Daemon.get

      %w(INT TERM).each do |sig|
        Signal.trap(sig) do
          Thread.new do
            d.stop
          end.join
        end
      end

      Process.setproctitle('osctld: main')
      OsCtl::Lib::Logger.setup(opts.log, facility: opts.log_facility)
      d.setup
    end
  end
end

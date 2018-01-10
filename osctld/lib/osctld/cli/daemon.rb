module OsCtld
  class Cli::Daemon
    def self.run(opts)
      d = OsCtld::Daemon.new

      %w(INT TERM).each do |sig|
        Signal.trap(sig) do
          Thread.new do
            d.stop
          end.join
        end
      end

      Process.setproctitle('osctld: main')
      Logger.setup(opts.log)
      d.setup
    end
  end
end

require 'libosctl'

module OsCtld
  class Cli::Daemon
    def self.run(opts)
      Process.setproctitle('osctld: main')
      OsCtl::Lib::Logger.setup(opts.log, facility: opts.log_facility)
      d = OsCtld::Daemon.create(opts.config)
      stopping = false

      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          next if stopping

          stopping = true

          Thread.new do
            d.stop
          end.join
        end
      end

      d.setup
    end
  end
end

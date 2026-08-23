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
            # Daemon#stop performs the same bounded drain as the management
            # API. When ownership cannot be resolved it deliberately stays
            # alive with callbacks available; allow a later signal or an
            # explicit resume after the condition is repaired.
            stopped = false
            begin
              stopped = d.stop
            rescue StandardError => e
              OsCtl::Lib::Logger.log(
                :fatal,
                "Unable to stop osctld safely: #{e.message} (#{e.class})"
              )
            ensure
              # A successful stop terminates the process from Daemon#stop.
              # Any return or exception means callbacks are still available
              # and a later signal must be allowed to try again.
              stopping = false unless stopped
            end
          end
        end
      end

      d.setup
    end
  end
end

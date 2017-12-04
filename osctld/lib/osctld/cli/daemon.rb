module OsCtld
  class Cli::Daemon
    def self.run
      d = OsCtld::Daemon.new

      %w(INT TERM).each do |sig|
        Signal.trap(sig) do
          Thread.new do
            d.stop
          end.join
        end
      end

      d.setup
    end
  end
end

require 'libosctl'

module OsCtl::Cli::Top
  class Tui::ModelThread
    # @return [Time, nil]
    attr_reader :last_measurement

    # @return [Integer]
    attr_reader :generation

    # @return [:realtime, :cumulative]
    attr_reader :mode

    def initialize(model, rate)
      @model = model
      @rate = rate
      @last_measurement = nil
      @generation = 0
      @mode = model.mode
      @data = { containers: [] }
      @queue = OsCtl::Lib::Queue.new
      @mutex = Mutex.new
    end

    def start
      @thread = Thread.new { work }
    end

    def stop
      @queue << [:stop]
      @thread.join
    end

    def get_data
      @mutex.synchronize do
        [@data, @last_measurement, @generation]
      end
    end

    # @param m [:realtime, :cumulative]
    def mode=(m)
      @queue << [:mode, m]
    end

    def iostat_enabled?
      @model.iostat_enabled?
    end

    def netif_enabled?
      @model.netif_enabled?
    end

    def zfs_enabled?
      @model.zfs_enabled?
    end

    def containers
      @model.containers
    end

    protected

    def work
      measure

      loop do
        cmd, *args = @queue.pop(timeout: @rate)
        return if cmd == :stop

        kwargs = {}

        if cmd == :mode
          kwargs[:mode] = args[0]
        end

        measure(**kwargs)
      end
    end

    def measure(mode: nil)
      @model.measure unless mode

      @mutex.synchronize do
        @last_measurement = Time.now unless mode

        if mode
          @model.mode = mode
          @mode = mode
        end

        @data = @model.data
        @generation += 1
      end
    end
  end
end

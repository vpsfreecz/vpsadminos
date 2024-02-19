module OsCtld
  class ProgressTracker
    def initialize(progress: 0, total: 0)
      @progress = progress
      @total = total
      @mutex = Mutex.new
    end

    def add_total(total)
      @mutex.synchronize { @total += total }
    end

    # @param message [String]
    # @param increment_by [Integer, nil]
    def progress_line(message, increment_by: 1)
      @mutex.synchronize do
        @progress += increment_by if increment_by

        "[#{@progress}/#{@total}] #{message}"
      end
    end
  end
end

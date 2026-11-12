require_relative 'worker'

module ImagePipeline
  # Each worker owns one serial image pipeline. Results are delivered as soon
  # as available; a slow build cannot hold a completed image behind a barrier.
  class Pool
    def initialize(items, workers:, factory:, result:, worker_retries: 1)
      raise ArgumentError, 'positive worker count required' unless workers > 0

      @pending = items.sort_by { |item| item.fetch('name').match?(/\A(?:guix|gentoo)/) ? 0 : 1 }
      @count = [workers, items.length].min
      @factory = factory
      @result = result
      @mutex = Mutex.new
      @result_mutex = Mutex.new
      @worker_retries = worker_retries
      @active_slow = 0
    end

    def run
      threads = @count.times.map do |index|
        Thread.new { work(index) }
      end
      errors = []
      threads.each do |thread|
        thread.value
      rescue StandardError => e
        errors << e
      end
      raise errors.first unless errors.empty?
    end

    protected

    def take(builder)
      @mutex.synchronize do
        # Affinity only considers the first few ready items; it never waits
        # for another worker or puts all quick work behind a long family.
        quick = @pending.index { |item| !slow?(item) }
        index = if quick && @active_slow >= @count - 1
                  quick
                else
                  @pending.first(4).index { |item| builder && item['builder'] == builder } || 0
                end
        item = @pending.delete_at(index)
        @active_slow += 1 if item && slow?(item)
        item
      end
    end

    def work(index)
      worker = nil
      builder = nil
      while (item = take(builder))
        retries = 0
        begin
          worker ||= @factory.call(index)
          outcome = worker.perform(item)
        rescue Worker::Failure => e
          worker.close
          worker = nil
          index += @count
          item['worker_failures'] ||= []
          item['worker_failures'] << e.message
          if retries < @worker_retries && item['assignment']
            retries += 1
            item['attempt'] = item.fetch('attempt') + 1
            retry
          end
          outcome = { 'status' => 'failed', 'assignment' => item['assignment'], 'message' => e.message }
        rescue StandardError => e
          outcome = { 'status' => 'failed', 'assignment' => item['assignment'], 'message' => "#{e.class}: #{e.message}" }
          # No reuse after an uncertain worker operation. Other workers keep
          # processing their queue and already verified results remain valid.
          worker&.close
          worker = nil
          index += @count
        end
        builder = outcome['builder']
        @result_mutex.synchronize { @result.call(item, outcome) }
        @mutex.synchronize { @active_slow -= 1 if slow?(item) }
      end
    ensure
      worker&.close
    end

    def slow?(item)
      item.fetch('name').match?(/\A(?:guix|gentoo)/)
    end
  end
end

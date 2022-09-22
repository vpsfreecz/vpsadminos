module OsCtl::Lib
  class ProcessList
    # Iterate over all processes
    # @param opts [Hash] options passed to {OsProcess}
    # @option opts [Integer, :auto] :threads number of threads to parse processes in
    # @yieldparam [OsProcess] process
    def self.each(**opts, &block)
      new(**opts).each(&block)
    end

    # Create an array of system processes
    #
    # The block can be used to filter out processes for which it returns false.
    # The process list is build in parallel, depending on the `:threads` option,
    # so the block can be invoked in parallel as well.
    #
    # @param opts [Hash] options passed to {OsProcess}
    # @option opts [Integer, :auto] :threads number of threads to parse processes in
    # @yieldparam [OsProcess] process
    def initialize(**opts, &block)
      @results = list_processes(**opts, &block)
    end

    def to_enum
      size = Proc.new do
        @results.inject(0) { |acc, result| acc + result.size }
      end

      Enumerator.new(size) do |yielder|
        result_it = @results.each

        loop do
          result = result_it.next
          process_it = result.each

          loop do
            yielder << process_it.next
          end
        end
      end
    end

    def each(&block)
      to_enum.each(&block)
    end

    include Enumerable

    protected
    def list_processes(threads: :auto, **opts, &block)
      num_threads =
        case threads
        when :auto
          8
        else
          threads
        end

      if num_threads == 1
        list_processes_serial(**opts, &block)
      else
        list_processes_parallel(num_threads, **opts, &block)
      end
    end

    def list_processes_serial(**opts, &block)
      result = []

      Dir.foreach('/proc') do |entry|
        process = parse_process(entry, opts, &block)
        result << process if process
      end

      [result]
    end

    def list_processes_parallel(num_threads, **opts, &block)
      queue = ::Queue.new
      results = num_threads.times.map { Array.new }

      work_threads = num_threads.times.map do |i|
        Thread.new { process_reader(queue, results[i], block, opts) }
      end

      Dir.foreach('/proc') do |entry|
        queue << entry
      end

      num_threads.times { queue << :stop }
      work_threads.each(&:join)

      results
    end

    def process_reader(queue, result, block, opts)
      loop do
        entry = queue.pop
        return if entry == :stop

        process = parse_process(entry, opts, &block)
        next if process.nil?

        result << process
      end
    end

    def parse_process(entry, opts)
      return if /^\d+$/ !~ entry || !Dir.exist?(File.join('/proc', entry))

      begin
        p = OsProcess.new(entry.to_i, **opts)
        return if block_given? && !yield(p)
        return p
      rescue Exceptions::OsProcessNotFound
        return
      end
    end
  end
end

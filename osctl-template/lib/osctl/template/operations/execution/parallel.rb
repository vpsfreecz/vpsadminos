require 'libosctl'
require 'osctl/template/operations/base'
require 'thread'

module OsCtl::Template
  class Operations::Execution::Parallel < Operations::Base
    Item = Struct.new(:obj, :block)
    Result = Struct.new(:status, :obj, :return_value, :exception)

    include OsCtl::Lib::Utils::Log

    # @return [Integer]
    attr_reader :jobs, :queue

    # @param jobs [Integer]
    def initialize(jobs)
      @jobs = jobs
      @mutex = ::Mutex.new
      @queue = OsCtl::Lib::Queue.new
      @threads = []
      @results = []
    end

    def add(obj, &block)
      queue << Item.new(obj, block)
    end

    # @return [Array<Result>]
    def execute
      jobs.times do |i|
        threads << Thread.new { work_loop(i) }
      end

      join_threads
      results
    end

    def stop
      queue.clear
    end

    protected
    attr_reader :threads, :mutex, :results

    def work_loop(i)
      loop do
        item = queue.shift(block: false)

        if item.nil?
          log(:info, "Worker ##{i} finished")
          return
        end

        log(:info, "Worker ##{i} executing job for #{item.obj}")

        begin
          ret = item.block.call
          exception = nil
        rescue => e
          log(:info, "Worker ##{i} caught exception: #{e.class}: #{e.message}")
          ret = nil
          exception = e
        end

        add_result(Result.new(
          exception.nil?,
          item.obj,
          ret,
          exception,
        ))
      end
    end

    def add_result(result)
      mutex.synchronize { results << result }
    end

    def join_threads
      threads.each(&:join)
    end
  end
end

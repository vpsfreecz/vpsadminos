require 'libosctl'
require 'singleton'

module OsCtld
  # Watches over a list of threads and waits for them to gracefully finish
  #
  # {ThreadReaper} is used to watch over per-client threads and join them when
  # they finish. When osctld is supposed to shut down, the reaper asks the
  # threads to prematurely exit and waits for all of them to finish their job.
  class ThreadReaper
    class << self
      %i(start stop add export).each do |m|
        define_method(m) do |*args, &block|
          instance.send(m, *args, &block)
        end
      end
    end

    include Singleton
    include OsCtl::Lib::Utils::Log

    def initialize
      @queue = OsCtl::Lib::Queue.new
      @mutex = Mutex.new
      @threads = []
    end

    def start
      @thread = Thread.new { run }
    end

    def stop
      queue << :stop
      thread && thread.join
    end

    # @param thread [Thread]
    # @param manager [Object, nil]
    def add(thread, manager)
      queue << [thread, manager]
    end

    def export
      sync { threads.clone }
    end

    protected
    attr_reader :queue, :thread, :threads

    def run
      do_stop = false

      loop do
        v = queue.pop(timeout: 0.1)

        if v.nil?
          join_dead_threads

        elsif v == :stop
          do_stop = true
          request_stop_threads

        elsif v.is_a?(Array)
          sync { threads << v }

        else
          fail "unknown command '#{v}'"
        end

        return if do_stop && can_stop?
      end
    end

    def join_dead_threads
      sync do
        threads.delete_if { |t, m| !t.alive? && t.join(0.05) }
      end
    end

    def request_stop_threads
      sync do
        threads.each { |t, m| t.alive? && m && m.request_stop }
      end
    end

    def can_stop?
      if sync { threads.empty? }
        true

      elsif @time.nil? || (Time.now - @time) >= 10
        @time = Time.now
        log(
          :info,
          'threadreaper',
          "Waiting for #{sync { threads.count }} threads to exit"
        )
        false
      end
    end

    def sync(&block)
      @mutex.synchronize(&block)
    end
  end
end

require 'libosctl'
require 'singleton'

module OsCtld
  # Watches over a list of threads and waits for them to gracefully finish
  #
  # {ThreadReaper} is used to watch over per-client threads and join them when
  # they finish. When osctld is supposed to shut down, the reaper asks the
  # threads to prematurely exit and waits for all of them to finish their job.
  class ThreadReaper
    DEFAULT_GROUP = :default
    DETACH_ON_STOP_GROUPS = %i[durable_lifecycle user_control].freeze

    class << self
      %i[start stop drain add export].each do |m|
        define_method(m) do |*args, **kwargs, &block|
          instance.send(m, *args, **kwargs, &block)
        end
      end
    end

    include Singleton
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::Exception

    def initialize
      @queue = OsCtl::Lib::Queue.new
      @mutex = Mutex.new
      @threads = []
      @drains = []
    end

    def start
      @thread = Thread.new { run }
    end

    def stop
      return unless thread

      queue << :stop
      thread.join
    end

    # Drain selected thread groups while the reaper remains active.
    #
    # Threads in other groups are left running and newly added threads in those
    # groups are not asked to stop. This is used during osctld shutdown to drain
    # public management clients while user-control callbacks needed by those
    # commands are still accepted.
    #
    # @param group [Symbol, nil]
    # @param groups [Array<Symbol>, nil]
    # @param stop [Boolean] ask matching managers to stop while draining
    def drain(group: nil, groups: nil, stop: true)
      return unless thread

      target_groups = normalize_groups(group:, groups:)
      ack = Queue.new

      queue << [:drain, target_groups, stop, ack]
      ack.pop
    end

    # @param thread [Thread]
    # @param manager [Object, nil]
    # @param group [Symbol]
    def add(thread, manager, group: DEFAULT_GROUP)
      queue << [:add, thread, manager, group]
    end

    def export
      sync { threads.map { |thread, manager, _group| [thread, manager] } }
    end

    protected

    attr_reader :queue, :thread, :threads, :drains, :stop_at

    def run
      @stopping = false

      loop do
        v = queue.pop(timeout: 0.1)

        if v.nil?
          join_dead_threads

        elsif v == :stop
          @stopping = true
          @stop_at = Time.now
          detach_on_stop_threads
          request_stop_threads

        elsif v.is_a?(Array) && v[0] == :drain
          _cmd, groups, stop, ack = v

          drains << [groups, stop, ack]
          request_stop_threads(groups:) if stop

        elsif v.is_a?(Array) && v[0] == :add
          _cmd, thread, manager, group = v

          unless @stopping && detach_on_stop_group?(group)
            request_stop_thread(thread, manager) if stop_thread_group?(group)
            sync { threads << [thread, manager, group] }
          end

        else
          raise "unknown command '#{v}'"
        end

        finish_drains

        return if @stopping && can_stop?
      end
    end

    def join_dead_threads
      sync do
        threads.delete_if { |t, _m, _group| !t.alive? && t.join(0.05) }
      end
    end

    def request_stop_threads(groups: nil)
      sync do
        threads.each do |thread, manager, group|
          next if groups && !groups.include?(thread_group(group))

          request_stop_thread(thread, manager)
        end
      end
    end

    def detach_on_stop_threads
      sync do
        threads.delete_if do |_thread, _manager, group|
          detach_on_stop_group?(group)
        end
      end
    end

    def detach_on_stop_group?(group)
      DETACH_ON_STOP_GROUPS.include?(thread_group(group))
    end

    def request_stop_thread(thread, manager)
      thread.alive? && manager && manager.request_stop
    end

    def stop_thread_group?(group)
      @stopping || drains.any? do |groups, stop, _ack|
        stop && groups.include?(thread_group(group))
      end
    end

    def finish_drains
      drains.delete_if do |groups, _stop, ack|
        next false unless groups_empty?(groups)

        ack << true
        true
      end
    end

    def groups_empty?(groups)
      sync do
        threads.none? { |_thread, _manager, group| groups.include?(thread_group(group)) }
      end
    end

    def can_stop?
      if sync { threads.empty? }
        true

      elsif @time.nil? || (Time.now - @time) >= 10
        @time = Time.now
        sync do
          log(
            :info,
            'threadreaper',
            "Waiting for #{threads.count} threads to exit"
          )

          if (Time.now - stop_at) >= 30
            threads.each_with_index do |v, i|
              t, m, group = v
              log(:info, 'threadreaper', "Thread ##{i + 1}: manager=#{m}")
              log(:info, 'threadreaper', "Thread ##{i + 1}: group=#{group}")
              log(:info, 'threadreaper', denixstorify(t.backtrace).join("\n"))
            end
          end
        end

        false
      end
    end

    def sync(&)
      @mutex.synchronize(&)
    end

    def normalize_groups(group:, groups:)
      ret = Array(groups || group)
      ret.compact!

      raise ArgumentError, 'no thread groups selected' if ret.empty?

      ret
    end

    def thread_group(group)
      group || DEFAULT_GROUP
    end
  end
end

require 'libosctl'
require 'singleton'

module OsCtl::Exporter
  class Collector
    include Singleton
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::File

    CollectorConfig = Struct.new(
      :collector_class,
      :require_osctld,
      :interval,
      :collector_instance,
      :registry,
    )

    ThreadConfig = Struct.new(
      :thread,
      :queue,
    )

    class << self
      %i(start stop).each do |m|
        define_method(m) do
          instance.send(m)
        end
      end
    end

    def initialize
      @threads = []
      @registry = OsCtl::Exporter.registry

      @collectors = [
        CollectorConfig.new(Collectors::ZpoolTxgs, false, 15),
        CollectorConfig.new(Collectors::OsCtld, false, 30),
        CollectorConfig.new(Collectors::Pool, true, 30),
        CollectorConfig.new(Collectors::Container, true, 30),
        CollectorConfig.new(Collectors::Exportfs, false, 60),
        CollectorConfig.new(Collectors::KernelKeyring, false, 60),
        CollectorConfig.new(Collectors::Sysctl, false, 60),
        CollectorConfig.new(Collectors::ZpoolList, false, 60),
        CollectorConfig.new(Collectors::HealthCheck, true, 120),
      ]

      @collectors.each do |c|
        c.registry = registry.new_registry(c.collector_class)
        c.collector_instance = c.collector_class.new(c.registry)
      end
    end

    def start
      unique_intervals = collectors.map(&:interval).uniq

      @threads = unique_intervals.map do |interval|
        queue = OsCtl::Lib::Queue.new
        thread_collectors = collectors.select { |c| c.interval == interval }
        client = OsCtldClient.new

        log(
          :info,
          "Starting collector thread with #{interval} second interval for: "+
          "#{thread_collectors.map { |c| c.collector_class.to_s.split('::').last }.join(', ')}"
        )

        thread = Thread.new do
          loop do
            collect(client, thread_collectors)
            break if queue.pop(timeout: interval) == :stop
          end
        end

        ThreadConfig.new(thread, queue)
      end

      nil
    end

    def stop
      return if threads.empty?

      threads.delete_if do |thread_cfg|
        thread_cfg.queue << :stop
        thread_cfg.thread.join
        true
      end

      nil
    end

    def log_type
      'collector'
    end

    protected
    attr_reader :threads, :registry, :collectors

    def collect(client, thread_collectors)
      client.try_to_connect do
        thread_collectors.reject(&:require_osctld).each do |c|
          c.registry.atomic_replace do
            c.collector_instance.run_collect(client)
          end
        end

        if client.connected?
          thread_collectors.select(&:require_osctld).each do |c|
            c.registry.atomic_replace do
              c.collector_instance.run_collect(client)
            end
          end
        end
      end
    end
  end
end

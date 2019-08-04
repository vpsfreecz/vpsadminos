require 'libosctl'
require 'singleton'

module OsCtl::Exporter
  class Collector
    include Singleton
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::File

    class << self
      %i(start stop).each do |m|
        define_method(m) do
          instance.send(m)
        end
      end
    end

    def initialize
      @client = OsCtldClient.new
      @queue = OsCtl::Lib::Queue.new
      @registry = Prometheus::Client.registry
      @collectors = [
        Collectors::Pool,
        Collectors::Container,
      ].map { |klass| klass.new(registry, client) }
    end

    def start
      @thread = Thread.new do
        loop do
          collect
          break if queue.pop(timeout: 30) == :stop
        end
      end
    end

    def stop
      if thread
        queue << :stop
        thread.join
        @thread = nil
      end
    end

    def log_type
      'collector'
    end

    protected
    attr_reader :client, :queue, :thread, :registry, :collectors

    def collect
      collectors.each { |c| c.collect }
    end
  end
end

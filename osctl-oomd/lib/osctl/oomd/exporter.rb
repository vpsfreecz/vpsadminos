require 'fileutils'
require 'libosctl'
require 'prometheus/client'
require 'prometheus/client/formats/text'

module OsCtl::Oomd
  class Exporter
    include OsCtl::Lib::Utils::File

    def initialize(file:, killer:)
      @file = file
      @killer = killer
      @queue = OsCtl::Lib::Queue.new
    end

    def start
      @thread = Thread.new { run_exporter }
    end

    def stop
      @queue << :stop
    end

    protected

    def run_exporter
      export_metrics

      loop do
        v = @queue.pop(timeout: 60)
        return if v == :stop

        export_metrics
      end
    end

    def export_metrics
      registry = Prometheus::Client::Registry.new
      metrics = setup_metrics(registry)
      collect_metrics(metrics)

      FileUtils.mkdir_p(File.dirname(@file))

      regenerate_file(@file, 0o644) do |new|
        new.write(Prometheus::Client::Formats::Text.marshal(registry))
      end
    end

    def setup_metrics(registry)
      @ct_restart_hits = registry.gauge(
        :osctl_oomd_container_restart_hits,
        docstring: 'Number of container OOM hits to restart',
        labels: %i[pool id]
      )

      @ct_stop_hits = registry.gauge(
        :osctl_oomd_container_stop_hits,
        docstring: 'Number of container OOM hits to stop',
        labels: %i[pool id]
      )

      @restart_hits = registry.gauge(
        :osctl_oomd_restart_hits,
        docstring: 'Number of hits to restart a container'
      )

      @stop_hits = registry.gauge(
        :osctl_oomd_stop_hits,
        docstring: 'Number of hits to stop a container'
      )
    end

    def collect_metrics(metrics)
      @killer.export.each do |ct|
        @ct_restart_hits.set(ct.restart_hits, labels: { pool: ct.pool, id: ct.id })
        @ct_stop_hits.set(ct.stop_hits, labels: { pool: ct.pool, id: ct.id })
      end

      @restart_hits.set(@killer.restart_hits)
      @stop_hits.set(@killer.stop_hits)
    end
  end
end

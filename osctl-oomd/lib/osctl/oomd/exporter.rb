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
      @ct_restart_seconds = registry.gauge(
        :osctl_oomd_container_restart_qualified_seconds,
        docstring: 'Qualified container restart seconds',
        labels: %i[pool id]
      )

      @ct_stop_seconds = registry.gauge(
        :osctl_oomd_container_stop_qualified_seconds,
        docstring: 'Qualified container load-gated stop seconds',
        labels: %i[pool id]
      )

      @restart_seconds = registry.gauge(
        :osctl_oomd_restart_after_seconds,
        docstring: 'Qualified seconds required to restart a container'
      )

      if @killer.respond_to?(:status)
        @status_metrics = %i[notification_drops notification_failures unknown_actions evidence_records evidence_bytes evidence_failures evidence_paused evidence_pending_records
                             rtnl_exposure_enabled rtnl_exposure_available rtnl_exposure_paused rtnl_exposure_gaps rtnl_exposure_batches
                             rtnl_exposure_pending_parts rtnl_exposure_event_failures].to_h do |name|
          [name, registry.gauge(:"osctl_oomd_#{name}", docstring: "OOMd #{name.to_s.tr('_', ' ')}")]
        end
      end

      @stop_seconds = registry.gauge(
        :osctl_oomd_stop_after_seconds,
        docstring: 'Qualified load-gated seconds required to stop a container'
      )
    end

    def collect_metrics(metrics)
      @killer.export.each do |ct|
        @ct_restart_seconds.set(ct.restart_qualified_seconds, labels: { pool: ct.pool, id: ct.id })
        @ct_stop_seconds.set(ct.stop_qualified_seconds, labels: { pool: ct.pool, id: ct.id })
      end

      if @status_metrics
        @killer.status.each { |name, value| @status_metrics.fetch(name).set(value) }
      end
      @restart_seconds.set(@killer.restart_after_seconds)
      @stop_seconds.set(@killer.stop_after_seconds)
    end
  end
end

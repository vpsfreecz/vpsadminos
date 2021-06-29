require 'libosctl'
require 'osctl/exporter/collectors/base'
require 'osctl/cli'
require 'osctl/cli/cgroup_params'

module OsCtl::Exporter
  class Collectors::Container < Collectors::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Cli::CGroupParams

    def setup
      @running = registry.gauge(
        :osctl_container_running,
        docstring: 'Marks running containers',
        labels: [:pool, :id],
      )
      @memory_used_bytes = registry.gauge(
        :osctl_container_memory_used_bytes,
        docstring: 'Memory used by containers',
        labels: [:pool, :id],
      )
      @cpu_ns_total = registry.gauge(
        :osctl_container_cpu_nanoseconds_total,
        docstring: 'Container CPU usage',
        labels: [:pool, :id, :mode],
      )
      @dataset_used = registry.gauge(
        :osctl_container_dataset_used_bytes,
        docstring: 'Dataset used space',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_referenced = registry.gauge(
        :osctl_container_dataset_referenced_bytes,
        docstring: 'Dataset referenced space',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_avail = registry.gauge(
        :osctl_container_dataset_avail_bytes,
        docstring: 'Dataset available space',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_quota = registry.gauge(
        :osctl_container_dataset_quota_bytes,
        docstring: 'Dataset quota',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_refquota = registry.gauge(
        :osctl_container_dataset_refquota_bytes,
        docstring: 'Dataset reference quota',
        labels: [:pool, :id, :dataset, :relative_name],
      )
    end

    def collect(client)
      cg_init_subsystems(client.client)
      cts = client.list_containers
      cg_add_stats(
        cts,
        lambda { |ct| ct[:group_path] },
        [:memory, :cpu_user_time, :cpu_sys_time],
        true
      )

      propreader = OsCtl::Lib::Zfs::PropertyReader.new

      begin
        tree = propreader.read(
          cts.map { |ct| ct[:dataset] },
          %i(used referenced available quota refquota),
          recursive: true,
        )
      rescue OsCtl::Lib::Exceptions::SystemCommandFailed => e
        log(:warn, "Unable to read dataset properties: exit status #{e.rc}, output: #{e.output.inspect}")
        return
      end

      cts.each do |ct|
        running.set(
          ct[:state] == 'running' ? 1 : 0,
          labels: {pool: ct[:pool], id: ct[:id]},
        )
        memory_used_bytes.set(
          ct[:memory].nil? ? 0 : ct[:memory].raw,
          labels: {pool: ct[:pool], id: ct[:id]},
        )
        cpu_ns_total.set(
          ct[:cpu_user_time].nil? ? 0 : ct[:cpu_user_time].raw,
          labels: {pool: ct[:pool], id: ct[:id], mode: 'user'},
        )
        cpu_ns_total.set(
          ct[:cpu_sys_time].nil? ? 0 : ct[:cpu_sys_time].raw,
          labels: {pool: ct[:pool], id: ct[:id], mode: 'system'},
        )

        tree[ct[:dataset]].each_tree_dataset do |tr_ds|
          ds = tr_ds.as_dataset(base: ct[:dataset])

          dataset_used.set(
            tr_ds.properties['used'].to_i,
            labels: dataset_labels(ct, ds),
          )
          dataset_referenced.set(
            tr_ds.properties['referenced'].to_i,
            labels: dataset_labels(ct, ds),
          )
          dataset_avail.set(
            tr_ds.properties['available'].to_i,
            labels: dataset_labels(ct, ds),
          )
          dataset_quota.set(
            tr_ds.properties['quota'].to_i,
            labels: dataset_labels(ct, ds),
          )
          dataset_refquota.set(
            tr_ds.properties['refquota'].to_i,
            labels: dataset_labels(ct, ds),
          )
        end
      end
    end

    protected
    attr_reader :running, :memory_total_bytes, :memory_used_bytes, :cpu_ns_total,
      :dataset_used, :dataset_referenced, :dataset_avail, :dataset_quota,
      :dataset_refquota

    def dataset_labels(ct, ds)
      {
        pool: ct[:pool],
        id: ct[:id],
        dataset: ds.name,
        relative_name: ds.relative_name,
      }
    end
  end
end

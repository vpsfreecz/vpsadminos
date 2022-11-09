require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::CpuScheduler < Collectors::Base
    def setup
      add_metric(
        :scheduler_enabled,
        :gauge,
        :osctl_cpu_scheduler_enabled,
        docstring: '1 if CPU scheduler is enabled, 0 otherwise',
      )
      add_metric(
        :scheduler_needed,
        :gauge,
        :osctl_cpu_scheduler_needed,
        docstring: '1 if CPU scheduler is needed, 0 otherwise',
      )
      add_metric(
        :scheduler_use,
        :gauge,
        :osctl_cpu_scheduler_use,
        docstring: '1 if CPU scheduler is in use, 0 otherwise',
      )
      add_metric(
        :package_enabled,
        :gauge,
        :osctl_cpu_package_enabled,
        docstring: '1 if CPU package is enabled, 0 otherwise',
        labels: %i(cpu_package),
      )
      add_metric(
        :package_containers,
        :gauge,
        :osctl_cpu_package_containers,
        docstring: 'Number of containers on a CPU package',
        labels: %i(cpu_package),
      )
      add_metric(
        :package_usage_score,
        :gauge,
        :osctl_cpu_package_usage_score,
        docstring: 'CPU package usage score',
        labels: %i(cpu_package),
      )
      add_metric(
        :package_cpu_us_total,
        :gauge,
        :osctl_cpu_package_cpu_microseconds_total,
        docstring: 'CPU time used by all containers on the CPU package, in microseconds',
        labels: %i(cpu_package mode),
      )
      add_metric(
        :package_memory_bytes,
        :gauge,
        :osctl_cpu_package_memory_used_bytes,
        docstring: 'Memory used by all containers on the CPU package, in bytes',
        labels: %i(cpu_package),
      )
    end

    def collect(client)
      st = client.cpu_scheduler_status

      @scheduler_enabled.set(st[:enabled] ? 1 : 0)
      @scheduler_needed.set(st[:needed] ? 1 : 0)
      @scheduler_use.set(st[:use] ? 1 : 0)

      pkgs = client.list_cpu_packages
      return if pkgs.size <= 1

      cts = manager.get_collector_by_class(Collectors::Container).get_last_container_data
      pkg_cts = {}

      if cts
        cts.each do |ct|
          pkg_id = ct[:cpu_package_inuse]
          next if pkg_id.nil?

          pkg_cts[pkg_id] ||= {cpu_user_us: 0, cpu_system_us: 0, memory_bytes: 0}
          pkg_cts[pkg_id][:cpu_user_us] += ct[:cpu_user_us].raw if ct[:cpu_user_us]
          pkg_cts[pkg_id][:cpu_system_us] += ct[:cpu_system_us].raw if ct[:cpu_system_us]
          pkg_cts[pkg_id][:memory_bytes] += ct[:memory].raw if ct[:memory]
        end
      end

      pkgs.each do |pkg|
        kwargs = {labels: {cpu_package: pkg[:id]}}

        @package_enabled.set(pkg[:enabled] ? 1 : 0, **kwargs)
        @package_containers.set(pkg[:containers], **kwargs)
        @package_usage_score.set(pkg[:usage_score], **kwargs)

        stats = pkg_cts[pkg[:id]]

        if stats
          stat_labels = {cpu_package: pkg[:id]}
          @package_cpu_us_total.set(stats[:cpu_user_us], labels: stat_labels.merge(mode: 'user'))
          @package_cpu_us_total.set(stats[:cpu_system_us], labels: stat_labels.merge(mode: 'system'))
          @package_memory_bytes.set(stats[:memory_bytes], **kwargs)
        end
      end
    end
  end
end

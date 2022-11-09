require 'osctl/exporter/collectors/base'

module OsCtl::Exporter
  class Collectors::Lxcfs < Collectors::Base
    def setup
      add_metric(
        :worker_enabled,
        :gauge,
        :osctl_lxcfs_worker_enabled,
        docstring: '1 if LXCFS worker is enabled, 0 otherwise',
        labels: %i(worker),
      )
      add_metric(
        :worker_size,
        :gauge,
        :osctl_lxcfs_worker_size,
        docstring: 'LXCFS worker size',
        labels: %i(worker),
      )
      add_metric(
        :worker_max_size,
        :gauge,
        :osctl_lxcfs_worker_max_size,
        docstring: 'LXCFS worker max size',
        labels: %i(worker),
      )
      add_metric(
        :worker_cpu_package,
        :gauge,
        :osctl_lxcfs_worker_cpu_package,
        docstring: 'LXCFS worker CPU package, -1 if on all CPUs',
        labels: %i(worker),
      )
      add_metric(
        :worker_loadavg,
        :gauge,
        :osctl_lxcfs_worker_loadavg,
        docstring: '1 if LXCFS worker has enabled loadavg tracking, 0 otherwise',
        labels: %i(worker),
      )
      add_metric(
        :worker_cfs,
        :gauge,
        :osctl_lxcfs_worker_cfs,
        docstring: '1 if LXCFS worker has enabled CPU view, 0 otherwise',
        labels: %i(worker),
      )
    end

    def collect(client)
      client.list_lxcfs_workers.each do |worker|
        kwargs = {labels: {worker: worker[:name]}}

        @worker_enabled.set(worker[:enabled] ? 1 : 0, **kwargs)
        @worker_size.set(worker[:size], **kwargs)
        @worker_max_size.set(worker[:max_size], **kwargs)
        @worker_cpu_package.set(worker[:cpu_package] ? worker[:cpu_package] : -1, **kwargs)
        @worker_loadavg.set(worker[:loadavg] ? 1 : 0, **kwargs)
        @worker_cfs.set(worker[:cfs] ? 1 : 0, **kwargs)
      end
    end
  end
end

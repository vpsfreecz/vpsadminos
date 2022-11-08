require 'osctl/cli/command'

module OsCtl::Cli
  class Lxcfs < Command
    WORKER_FIELDS = %i(
      name
      enabled
      size
      max_size
      cpu_package
      loadavg
      cfs
      mountpoint
    )

    DEFAULT_WORKER_FIELDS = WORKER_FIELDS - %i(mountpoint)

    def worker_list
      require_args!

      if opts[:list]
        puts (WORKER_FIELDS).join("\n")
        return
      end

      cols =
        if opts[:output]
          opts[:output].split(',').map(&:to_sym)
        else
          DEFAULT_WORKER_FIELDS
        end

      fmt_opts = {
        layout: :columns,
        cols: cols,
        sort: opts[:sort] ? opts[:sort].split(',').map(&:to_sym) : nil,
      }

      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(:lxcfs_worker_list, fmt_opts: fmt_opts)
    end

    def worker_enable
      require_args!('worker')
      osctld_fmt(:lxcfs_worker_enable, cmd_opts: {worker: args[0]})
    end

    def worker_disable
      require_args!('worker')
      osctld_fmt(:lxcfs_worker_disable, cmd_opts: {worker: args[0]})
    end

    def worker_set_max_size
      require_args!('worker', 'max-size')
      osctld_fmt(:lxcfs_worker_set, cmd_opts: {worker: args[0], max_size: args[1].to_i})
    end

    def worker_prune
      osctld_fmt(:lxcfs_worker_prune)
    end
  end
end

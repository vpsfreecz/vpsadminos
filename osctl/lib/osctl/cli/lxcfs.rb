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

      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: WORKER_FIELDS,
        default_params: DEFAULT_WORKER_FIELDS,
      )

      if opts[:list]
        puts param_selector
        return
      end

      fmt_opts = {
        layout: :columns,
        cols: param_selector.parse_option(opts[:output]),
        sort: opts[:sort] && param_selector.parse_option(opts[:sort]),
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

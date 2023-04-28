require 'osctl/cli/command'
require 'libosctl'

module OsCtl::Cli
  class CpuScheduler < Command
    PACKAGE_FIELDS = %i(
      id
      cpus
      ncpus
      containers
      containers_per_cpu
      usage_score
      usage_score_per_cpu
      enabled
    )

    def status
      require_args!
      osctld_fmt(:cpu_scheduler_status)
    end

    def enable
      require_args!
      osctld_fmt(:cpu_scheduler_enable)
    end

    def disable
      require_args!
      osctld_fmt(:cpu_scheduler_disable)
    end

    def upkeep
      require_args!
      osctld_fmt(:cpu_scheduler_upkeep)
    end

    def package_list
      require_args!

      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: PACKAGE_FIELDS,
      )

      if opts[:list]
        puts param_selector
        return
      end

      fmt_opts = {
        layout: :columns,
        cols: param_selector.parse_option(opts[:output]),
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
        opts: {
          cpus: {
            label: 'CPUS',
            display: Proc.new { |v| OsCtl::Lib::CpuMask.format(v) },
          },
        },
      }

      fmt_opts[:header] = false if opts['hide-header']

      packages = osctld_call(:cpu_scheduler_package_list)

      packages.each do |pkg|
        ncpus = pkg[:cpus].size
        ncpus_f = ncpus.to_f

        pkg[:ncpus] = ncpus
        pkg[:containers_per_cpu] = (pkg[:containers] / ncpus_f).round(2)
        pkg[:usage_score_per_cpu] = (pkg[:usage_score] / ncpus_f).round(2)
      end

      format_output(packages, **fmt_opts)
    end

    def package_enable
      require_args!('package')
      osctld_fmt(:cpu_scheduler_package_enable, cmd_opts: {package: args[0].to_i})
    end

    def package_disable
      require_args!('package')
      osctld_fmt(:cpu_scheduler_package_disable, cmd_opts: {package: args[0].to_i})
    end
  end
end

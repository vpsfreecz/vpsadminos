require 'osctl/cli/command'

module OsCtl::Cli
  class CpuScheduler < Command
    PACKAGE_FIELDS = %i(id cpus containers idle enabled last_check)

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

    def package_list
      require_args!

      if opts[:list]
        puts (PACKAGE_FIELDS).join("\n")
        return
      end

      cols =
        if opts[:output]
          opts[:output].split(',').map(&:to_sym)
        else
          PACKAGE_FIELDS
        end

      cpus_i = cols.index(:cpus)

      if cpus_i
        cols[cpus_i] = {
          name: :cpus,
          label: 'CPUS',
          display: Proc.new { |v| format_cpumask(v) },
        }
      end

      fmt_opts = {
        layout: :columns,
        cols: cols,
        sort: opts[:sort] ? opts[:sort].split(',').map(&:to_sym) : %i(idle),
      }

      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(:cpu_scheduler_package_list, fmt_opts: fmt_opts)
    end

    def package_enable
      require_args!('package')
      osctld_fmt(:cpu_scheduler_package_enable, cmd_opts: {package: args[0].to_i})
    end

    def package_disable
      require_args!('package')
      osctld_fmt(:cpu_scheduler_package_disable, cmd_opts: {package: args[0].to_i})
    end

    protected
    def format_cpumask(cpu_list)
      return if cpu_list.empty?

      groups = []
      acc = []
      prev = nil

      cpu_list.each do |cpu|
        if prev.nil? || cpu == prev+1
          prev = cpu
          acc << cpu
        else
          groups << format_cpumask_range(acc)
          prev = nil
          acc = [cpu]
        end
      end

      groups << format_cpumask_range(acc)
      groups.join(',')
    end

    def format_cpumask_range(acc)
      len = acc.length

      if len == 1
        acc.first
      elsif len == 2
        acc.join(',')
      elsif len > 2
        "#{acc.first}-#{acc.last}"
      else
        nil
      end
    end
  end
end

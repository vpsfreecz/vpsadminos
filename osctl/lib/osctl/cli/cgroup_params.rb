require 'libosctl'

module OsCtl
  module Cli::CGroupParams
    CGPARAM_FIELDS = %i[
      version
      subsystem
      parameter
      value
      group
      abs_path
    ].freeze

    CGPARAM_FILTERS = %i[
      subsystem
    ].freeze

    CGPARAM_DEFAULT_FIELDS = %i[
      version
      parameter
      value
    ].freeze

    CGPARAM_STATS = %i[
      memory
      memory_pct
      kmemory
      cpu_us
      cpu_user_us
      cpu_system_us
      cpu_hz
      cpu_user_hz
      cpu_system_hz
      nproc
    ].freeze

    def do_cgparam_list(cmd, cmd_opts)
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: CGPARAM_FIELDS,
        default_params: CGPARAM_DEFAULT_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      fmt_opts = { layout: :columns }

      case opts[:version]
      when '1', '2'
        cmd_opts[:version] = opts[:version].to_i
      when 'all'
        # nothing to do
      else
        raise GLI::BadCommandLine, "invalid cgroup version '#{opts[:version]}'"
      end

      cmd_opts[:parameters] = args[1..] if args.count > 1
      cmd_opts[:subsystem] = opts[:subsystem].split(',') if opts[:subsystem]
      cmd_opts[:all] = true if opts[:all]
      fmt_opts[:header] = false if opts['hide-header']

      cols = param_selector.parse_option(opts[:output])

      if opts[:output].nil? && opts[:all]
        cols.insert(0, :group)
      end

      fmt_opts[:opts] = {
        value: {
          label: 'VALUE',
          align: 'right',
          display: proc do |values|
            values.map do |v|
              if gopts[:parsable] \
                 || gopts[:json] \
                 || (!v.is_a?(Integer) && /^\d+$/ !~ v)
                next v
              end

              humanize_data(v.to_i)
            end.join('; ')
          end
        }
      }

      fmt_opts[:cols] = cols

      osctld_fmt(
        cmd,
        cmd_opts:,
        fmt_opts:
      )
    end

    def do_cgparam_set(cmd, cmd_opts, params = nil)
      params ||= [{
        version: opts[:version],
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
        value: args[2..].map { |v| parse_data(v) }
      }.compact]

      cmd_opts.update({
        parameters: params,
        append: opts[:append]
      })

      osctld_fmt(cmd, cmd_opts:)
    end

    def do_cgparam_unset(cmd, cmd_opts, params = nil)
      params ||= [{
        version: opts[:version],
        subsystem: parse_subsystem(args[1]),
        parameter: args[1]
      }.compact]

      cmd_opts.update(parameters: params)

      osctld_fmt(cmd, cmd_opts:)
    end

    def do_cgparam_apply(cmd, cmd_opts)
      osctld_fmt(cmd, cmd_opts:)
    end

    def do_cgparam_replace(cmd, cmd_opts)
      osctld_fmt(cmd, cmd_opts: cmd_opts.merge(
        parameters: JSON.parse($stdin.read)['parameters']
      ))
    end

    def do_set_cpu_limit(cmd, cmd_opts)
      quota = args[1].to_f / 100 * opts[:period]

      params = [
        # cgroup v2
        {
          version: 2,
          subsystem: 'cpu',
          parameter: 'cpu.max',
          value: ["#{quota.round} #{opts[:period]}"]
        },
        # cgroup v1
        {
          version: 1,
          subsystem: 'cpu',
          parameter: 'cpu.cfs_period_us',
          value: [opts[:period]]
        },
        {
          version: 1,
          subsystem: 'cpu',
          parameter: 'cpu.cfs_quota_us',
          value: [quota.round]
        }
      ]

      do_cgparam_set(cmd, cmd_opts, params)
    end

    def do_unset_cpu_limit(unset_cmd, cmd_opts)
      params = [
        # cgroup v2
        {
          version: 2,
          subsystem: 'cpu',
          parameter: 'cpu.max'
        },
        # cgroup v1
        {
          version: 1,
          subsystem: 'cpu',
          parameter: 'cpu.cfs_period_us'
        },
        {
          version: 1,
          subsystem: 'cpu',
          parameter: 'cpu.cfs_quota_us'
        }
      ]

      do_cgparam_unset(unset_cmd, cmd_opts, params)
    end

    def do_set_memory(set_cmd, _unset_cmd, cmd_opts)
      mem = parse_data(args[1])
      swap = parse_data(args[2]) if args[2]

      limits = []

      # cgroup v2
      limits << {
        version: 2,
        subsystem: 'memory',
        parameter: 'memory.max',
        value: [mem]
      }

      limits << if swap
                  {
                    version: 2,
                    subsystem: 'memory',
                    parameter: 'memory.swap.max',
                    value: [swap]
                  }
                else
                  {
                    version: 2,
                    subsystem: 'memory',
                    parameter: 'memory.swap.max',
                    value: ['0']
                  }
                end

      # cgroup v1
      limits << {
        version: 1,
        subsystem: 'memory',
        parameter: 'memory.limit_in_bytes',
        value: [mem]
      }

      limits << if swap
                  {
                    version: 1,
                    subsystem: 'memory',
                    parameter: 'memory.memsw.limit_in_bytes',
                    value: [mem + swap]
                  }
                else
                  {
                    version: 1,
                    subsystem: 'memory',
                    parameter: 'memory.memsw.limit_in_bytes',
                    value: [mem]
                  }
                end

      do_cgparam_set(set_cmd, cmd_opts, limits)
    end

    def do_unset_memory(unset_cmd, cmd_opts)
      params = [
        # cgroup v2
        {
          version: 2,
          subsystem: 'memory',
          parameter: 'memory.swap.max'
        },
        {
          version: 2,
          subsystem: 'memory',
          parameter: 'memory.max'
        },
        # cgroup v1
        {
          version: 1,
          subsystem: 'memory',
          parameter: 'memory.memsw.limit_in_bytes'
        },
        {
          version: 1,
          subsystem: 'memory',
          parameter: 'memory.limit_in_bytes'
        }
      ]

      do_cgparam_unset(unset_cmd, cmd_opts, params)
    end

    # @param client [OsCtl::Client]
    def cg_init_subsystems(client)
      @cg_subsystems ||= if OsCtl::Lib::CGroup.v2?
                           { nil => OsCtl::Lib::CGroup::FS }
                         else
                           client.cmd_data!(:group_cgsubsystems)
                         end
      nil
    end

    # Add runtime stats from CGroup parameters to `data`
    #
    # {#cg_init_subsystems} must be called before this method can be used.
    #
    # @param data [Hash, Array] hash/array to which the stats are added
    # @param path [String] path of the chosen group
    # @param params [Array] selected stat parameters
    # @param precise [Boolean] humanize parameter values?
    # @return [Hash, Array] data extended with stats
    def cg_add_stats(data, path, params, precise)
      fields = CGPARAM_STATS & params

      if data.is_a?(::Hash)
        cg_reader = OsCtl::Lib::CGroup::PathReader.new(@cg_subsystems, path)

        data.update(cg_reader.read_stats(fields, precise))
        data

      elsif data.is_a?(::Array)
        data.map do |v|
          cg_reader = OsCtl::Lib::CGroup::PathReader.new(@cg_subsystems, path.call(v))
          v.update(cg_reader.read_stats(fields, precise))
        end
      end
    end

    # Return a list of readable cgroup parameters from all subsystems
    #
    # {#cg_init_subsystems} must be called before this method can be used.
    #
    # @return [Array<String>]
    def cg_list_raw_cgroup_params
      cg_reader = OsCtl::Lib::CGroup::PathReader.new(@cg_subsystems, 'osctl')
      cg_reader.list_available_params
    end

    # Read and add cgroup parameters to `data`
    #
    # {#cg_init_subsystems} must be called before this method can be used.
    #
    # @param data [Hash, Array] hash/array to which the stats are added
    # @param path [String, Proc] path of the chosen group
    # @param params [Array] selected cgroup parameters
    # @return [Hash, Array] data extended with cgroup params
    def cg_add_raw_cgroup_params(data, path, params)
      if data.is_a?(::Hash)
        cg_reader = OsCtl::Lib::CGroup::PathReader.new(@cg_subsystems, path)
        data.update(cg_reader.read_params(params))
        data

      elsif data.is_a?(::Array)
        data.map do |v|
          cg_reader = OsCtl::Lib::CGroup::PathReader.new(@cg_subsystems, path.call(v))
          v.update(cg_reader.read_params(params))
        end
      end
    end

    protected

    def parse_cgparams
      opts[:cgparam].map do |v|
        parts = v.split('=')

        unless parts.count == 2
          raise "invalid cgparam '#{v}': expected <parameter>=<value>"
        end

        k, v = parts

        {
          subsystem: parse_subsystem(k),
          parameter: k,
          value: parse_data(v)
        }
      end
    end

    def parse_subsystem(param)
      param.split('.').first
    end
  end
end

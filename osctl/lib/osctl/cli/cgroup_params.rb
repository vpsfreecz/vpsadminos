require 'libosctl'

module OsCtl
  module Cli::CGroupParams
    CGPARAM_FIELDS = %i(
      version
      subsystem
      parameter
      value
      group
      abs_path
    )

    CGPARAM_FILTERS = %i(
      subsystem
    )

    CGPARAM_DEFAULT_FIELDS = %i(
      version
      parameter
      value
    )

    CGPARAM_STATS = %i(
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
    )

    def do_cgparam_list(cmd, cmd_opts)
      if opts[:list]
        puts CGPARAM_FIELDS.join("\n")
        return
      end

      fmt_opts = {layout: :columns}

      case opts[:version]
      when '1', '2'
        cmd_opts[:version] = opts[:version].to_i
      when 'all'
      else
        raise GLI::BadCommandLine, "invalid cgroup version '#{opts[:version]}'"
      end

      cmd_opts[:parameters] = args[1..-1] if args.count > 1
      cmd_opts[:subsystem] = opts[:subsystem].split(',') if opts[:subsystem]
      cmd_opts[:all] = true if opts[:all]
      fmt_opts[:header] = false if opts['hide-header']

      if opts[:output]
        cols = opts[:output].split(',').map(&:to_sym)

      elsif opts[:all]
        cols = %i(group) + CGPARAM_DEFAULT_FIELDS

      else
        cols = CGPARAM_DEFAULT_FIELDS
      end

      if i = cols.index(:value)
        cols[i] = {
          name: :value,
          label: 'VALUE',
          align: 'right',
          display: Proc.new do |values|
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
      end

      osctld_fmt(
        cmd,
        cmd_opts,
        cols,
        fmt_opts
      )
    end

    def do_cgparam_set(cmd, cmd_opts, params = nil)
      params ||= [{
        version: opts[:version],
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
        value: args[2..-1].map { |v| parse_data(v) },
      }.compact]

      cmd_opts.update({
        parameters: params,
        append: opts[:append],
      })

      osctld_fmt(cmd, cmd_opts)
    end

    def do_cgparam_unset(cmd, cmd_opts, params = nil)
      params ||= [{
        version: opts[:version],
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
      }.compact]

      cmd_opts.update(parameters: params)

      osctld_fmt(cmd, cmd_opts)
    end

    def do_cgparam_apply(cmd, cmd_opts)
      osctld_fmt(cmd, cmd_opts)
    end

    def do_cgparam_replace(cmd, cmd_opts)
      osctld_fmt(cmd, cmd_opts.merge(
        parameters: JSON.parse(STDIN.read)['parameters'],
      ))
    end

    def do_set_cpu_limit(cmd, cmd_opts)
      quota = args[1].to_f / 100 * opts[:period]

      params =
        if OsCtl::Lib::CGroup.v2?
          [
            {
              subsystem: 'cpu',
              parameter: 'cpu.max',
              value: ["#{quota.round} #{opts[:period]}"]
            },
          ]
        else
          [
            {
              subsystem: 'cpu',
              parameter: 'cpu.cfs_period_us',
              value: [opts[:period]],
            },
            {
              subsystem: 'cpu',
              parameter: 'cpu.cfs_quota_us',
              value: [quota.round],
            },
          ]
        end

      do_cgparam_set(cmd, cmd_opts, params)
    end

    def do_unset_cpu_limit(unset_cmd, cmd_opts)
      params =
        if OsCtl::Lib::CGroup.v2?
          [
            {
              subsystem: 'cpu',
              parameter: 'cpu.max',
            }
          ]
        else
          [
            {
              subsystem: 'cpu',
              parameter: 'cpu.cfs_period_us',
            },
            {
              subsystem: 'cpu',
              parameter: 'cpu.cfs_quota_us',
            },
          ]
        end

      do_cgparam_unset(unset_cmd, cmd_opts, params)
    end

    def do_set_memory(set_cmd, unset_cmd, cmd_opts)
      mem = parse_data(args[1])
      swap = parse_data(args[2]) if args[2]

      limits = []

      if OsCtl::Lib::CGroup.v2?
        limits << {
          subsystem: 'memory',
          parameter: 'memory.max',
          value: [mem],
        }

        if swap
          limits << {
            subsystem: 'memory',
            parameter: 'memory.swap.max',
            value: [swap],
          }
        else
          limits << {
            subsystem: 'memory',
            parameter: 'memory.swap.max',
            value: ['max'],
          }
        end

      else
        limits << {
          subsystem: 'memory',
          parameter: 'memory.limit_in_bytes',
          value: [mem],
        }

        if swap
          limits << {
            subsystem: 'memory',
            parameter: 'memory.memsw.limit_in_bytes',
            value: [mem+swap],
          }
        else
          limits << {
            subsystem: 'memory',
            parameter: 'memory.memsw.limit_in_bytes',
            value: [mem],
          }
        end
      end

      do_cgparam_set(set_cmd, cmd_opts, limits)
    end

    def do_unset_memory(unset_cmd, cmd_opts)
      params =
        if OsCtl::Lib::CGroup.v2?
          [
            {
              subsystem: 'memory',
              parameter: 'memory.swap.max',
            },
            {
              subsystem: 'memory',
              parameter: 'memory.max',
            },
          ]
        else
          [
            {
              subsystem: 'memory',
              parameter: 'memory.memsw.limit_in_bytes',
            },
            {
              subsystem: 'memory',
              parameter: 'memory.limit_in_bytes',
            },
          ]
        end

      do_cgparam_unset(unset_cmd, cmd_opts, params)
    end

    # Read select CGroup parameters
    # @param subsystems [Hash] subsystem => absolute path
    # @param path [String] path of chosen group, relative to the subsystem
    # @param params [Array] parameters to read
    # @param precise [Boolean] humanize parameter values?
    # @return [Hash] parameter => value
    def cg_read_stats(subsystems, path, params, precise)
      ret = {}

      params.each do |field|
        begin
          next if ret[field]

          v =
            if OsCtl::Lib::CGroup.v1?
              cg_read_stats_param_v1(subsystems, path, field, precise)
            else
              cg_read_stats_param_v2(path, field, precise)
            end

          next if v.nil?

          if v.is_a?(Hash)
            ret.update(v)
          else
            ret[field] = v
          end

        rescue Errno::ENOENT
          ret[field] = nil
        end
      end

      ret
    end

    def cg_read_stats_param_v1(subsystems, path, field, precise)
      case field
      when :memory
        t = read_memory_usage_v1(subsystems[:memory], path)
        OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_data(t))

      when :kmemory
        t = read_cgparam_v1(
          subsystems[:memory],
          path,
          'memory.kmem.usage_in_bytes'
        ).to_i
        OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_data(t))

      when :memory_pct
        limit = read_memory_limit_v1(subsystems[:memory], path)
        usage = read_memory_usage_v1(subsystems[:memory], path)
        t = usage.to_f / limit * 100
        OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_percent(t))

      when :cpu_us, :cpu_user_us, :cpu_system_us
        all = read_cgparam_v1(
          subsystems[:cpuacct],
          path,
          'cpuacct.usage'
        ).to_i / 1_000

        user = read_cgparam_v1(
          subsystems[:cpuacct],
          path,
          'cpuacct.usage_user'
        ).to_i / 1_000

        sys = read_cgparam_v1(
          subsystems[:cpuacct],
          path,
          'cpuacct.usage_sys'
        ).to_i / 1_000

        {
          cpu_us: OsCtl::Lib::Cli::Presentable.new(
            all, formatted: precise ? nil : humanize_time_us(all)
          ),
          cpu_user_us: OsCtl::Lib::Cli::Presentable.new(
            user, formatted: precise ? nil : humanize_time_us(user)
          ),
          cpu_system_us: OsCtl::Lib::Cli::Presentable.new(
            sys, formatted: precise ? nil : humanize_time_us(sys)
          ),
        }

      when :cpu_hz, :cpu_user_hz, :cpu_system_hz
        Hash[
          read_cgparam_v1(
            subsystems[:cpuacct],
            path,
            'cpuacct.stat'
          ).split("\n").map do |line|
            type, hz = line.split(' ')
            [:"cpu_#{type}_hz", hz.to_i]
          end
        ]

      when :nproc
        read_cgparam_v1(
          subsystems[:pids],
          path,
          'pids.current'
        ).to_i

      else
        nil
      end
    end

    # @param memory [String] absolute path to memory subsystem
    # @param path [String] path of chosen group, relative to the subsystem
    # @return [Integer]
    def read_memory_usage_v1(memory, path)
      read_cgparam_v1(memory, path, 'memory.memsw.usage_in_bytes').to_i
    end

    # @param memory [String] absolute path to memory subsystem
    # @param path [String] path of chosen group, relative to the subsystem
    # @return [Integer]
    def read_memory_limit_v1(memory, path)
      unlimited = 9223372036854771712

      if path.end_with?('/user-owned')
        path = path.split('/')[0..-2].join('/')
      end

      v = read_cgparam_v1(memory, path, 'memory.memsw.limit_in_bytes').to_i
      return v if v != unlimited

      v = read_cgparam_v1(memory, path, 'memory.limit_in_bytes').to_i
      return v if v != unlimited

      # TODO: this could be optimised to read meminfo just once for all containers
      mi = OsCtl::Cli::MemInfo.new
      mi.total * 1024
    end

    def cg_read_stats_param_v2(path, field, precise)
      case field
      when :memory
        t = read_cgparam_v2(path, 'memory.current').to_i
        OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_data(t))

      when :kmemory
        nil

      when :memory_pct
        limit = read_memory_limit_v2(path)
        usage = read_cgparam_v2(path, 'memory.current').to_i
        t = usage.to_f / limit * 100
        OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_percent(t))

      when :cpu_us, :cpu_user_us, :cpu_system_us
        stat = read_cpu_stat_v2(path)

        {
          cpu_us: OsCtl::Lib::Cli::Presentable.new(
            stat[:all], formatted: precise ? nil : humanize_time_us(stat[:all])
          ),
          cpu_user_us: OsCtl::Lib::Cli::Presentable.new(
            stat[:user], formatted: precise ? nil : humanize_time_us(stat[:user])
          ),
          cpu_system_us: OsCtl::Lib::Cli::Presentable.new(
            stat[:system], formatted: precise ? nil : humanize_time_us(stat[:system])
          ),
        }

      when :cpu_hz, :cpu_user_hz, :cpu_system_hz
        stat = read_cpu_stat_v2(path)

        {
          cpu_user_hz: stat[:user] / (1_000_000 / OsCtl::Lib::OsProcess::TICS_PER_SECOND),
          cpu_system_hz: stat[:system] / (1_000_000 / OsCtl::Lib::OsProcess::TICS_PER_SECOND),
        }

      when :nproc
        read_cgparam_v2(path, 'pids.current').to_i

      else
        nil
      end
    end

    # @param path [String] path of chosen group, relative to the subsystem
    # @return [Integer]
    def read_memory_limit_v2(path)
      unlimited = 'max'

      if path.end_with?('/user-owned')
        path = path.split('/')[0..-2].join('/')
      end

      v = read_cgparam_v2(path, 'memory.max').to_i
      return v if v != unlimited

      # TODO: this could be optimised to read meminfo just once for all containers
      mi = OsCtl::Cli::MemInfo.new
      mi.total * 1024
    end

    # @return [Hash] cpu usage in microseconds
    def read_cpu_stat_v2(path)
      params = Hash[read_cgparam_v2(path, 'cpu.stat').strip.split("\n").map(&:split)]

      {
        all: params['usage_usec'].to_i,
        user: params['user_usec'].to_i,
        system: params['system_usec'].to_i,
      }
    end

    # @param client [OsCtl::Client]
    def cg_init_subsystems(client)
      if OsCtl::Lib::CGroup.v2?
        @cg_subsystems ||= {nil => OsCtl::Lib::CGroup::FS}
      else
        @cg_subsystems ||= client.cmd_data!(:group_cgsubsystems)
      end
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
        data.update(cg_read_stats(@cg_subsystems, path, fields, precise))
        data

      elsif data.is_a?(::Array)
        data.map do |v|
          v.update(cg_read_stats(@cg_subsystems, path.call(v), fields, precise))
        end
      end
    end

    # Return a list of readable cgroup parameters from all subsystems
    #
    # {#cg_init_subsystems} must be called before this method can be used.
    #
    # @return [Array<String>]
    def cg_list_raw_cgroup_params
      params = []

      @cg_subsystems.each do |name, path|
        cgpath = File.join(path, 'osctl')

        begin
          entries = Dir.entries(cgpath)
        rescue Errno::ENOENT
          # the /osctl cgroup does not exist when there are no containers
          return params
        end

        entries.each do |v|
          next if %w(. .. notify_on_release release_agent tasks).include?(v)
          next if v.start_with?('cgroup.')

          st = File.stat(File.join(cgpath, v))
          next if st.directory?

          # Ignore files that do not have read by user permission
          next if (st.mode & 0400) != 0400

          params << v
        end
      end

      params.uniq!
      params.sort!
    end

    # Read selected cgroup parameters
    # @param subsystems [Hash]
    # @param path [String]
    # @param params [Array]
    # @return [Hash]
    def cg_read_raw_cgroup_params(subsystems, path, params)
      ret = {}

      if path.end_with?('/user-owned')
        path = path.split('/')[0..-2].join('/')
      end

      params.each do |par|
        begin
          ret[par.to_sym] = read_cgparam(
            subsystems[parse_subsystem(par.to_s).to_sym],
            path,
            par.to_s,
          )
        rescue Errno::ENOENT
          ret[par.to_sym] = nil
        end
      end

      ret
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
        data.update(cg_read_raw_cgroup_params(@cg_subsystems, path, params))
        data

      elsif data.is_a?(::Array)
        data.map do |v|
          v.update(cg_read_raw_cgroup_params(@cg_subsystems, path.call(v), params))
        end
      end
    end

    protected
    def parse_memory_stat(memory, path)
      Hash[
        read_cgparam(memory, path, 'memory.stat').split("\n").map do |line|
          param, value = line.split
          [param.to_sym, value.to_i]
        end
      ]
    end

    def parse_cgparams
      opts[:cgparam].map do |v|
        parts = v.split('=')

        unless parts.count == 2
          fail "invalid cgparam '#{v}': expected <parameter>=<value>"
        end

        k, v = parts

        {
          subsystem: parse_subsystem(k),
          parameter: k,
          value: parse_data(v),
        }
      end
    end

    def parse_subsystem(param)
      param.split('.').first
    end

    def read_cgparam_v1(subsys_path, group_path, param)
      File.read(File.join(subsys_path, group_path, param)).strip
    end

    def read_cgparam_v2(group_path, param)
      File.read(File.join(OsCtl::Lib::CGroup::FS, group_path, param)).strip
    end
  end
end

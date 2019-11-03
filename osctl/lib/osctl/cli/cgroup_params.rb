require 'libosctl'

module OsCtl
  module Cli::CGroupParams
    CGPARAM_FIELDS = %i(
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
      parameter
      value
    )

    CGPARAM_STATS = %i(
      memory
      kmemory
      cpu_time
      cpu_user_time
      cpu_sys_time
      cpu_stat
      nproc
    )

    def do_cgparam_list(cmd, cmd_opts)
      if opts[:list]
        puts CGPARAM_FIELDS.join("\n")
        return
      end

      fmt_opts = {layout: :columns}

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
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
        value: args[2..-1].map { |v| parse_data(v) },
      }]

      cmd_opts.update({
        parameters: params,
        append: opts[:append],
      })

      osctld_fmt(cmd, cmd_opts)
    end

    def do_cgparam_unset(cmd, cmd_opts, params = nil)
      params ||= [{
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
      }]

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

      do_cgparam_set(
        cmd,
        cmd_opts,
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
      )
    end

    def do_unset_cpu_limit(unset_cmd, cmd_opts)
      do_cgparam_unset(
        unset_cmd,
        cmd_opts,
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
      )
    end

    def do_set_memory(set_cmd, unset_cmd, cmd_opts)
      mem = parse_data(args[1])
      swap = parse_data(args[2]) if args[2]

      limits = [
        {
          subsystem: 'memory',
          parameter: 'memory.limit_in_bytes',
          value: [mem],
        },
      ]

      if swap
        limits << {
          subsystem: 'memory',
          parameter: 'memory.memsw.limit_in_bytes',
          value: [mem+swap],
        }

      else
        # When no swap limit is to be set, we have to remove existing swap
        # limits
        do_cgparam_unset(unset_cmd, cmd_opts, [{
          subsystem: 'memory',
          parameter: 'memory.memsw.limit_in_bytes',
        }])
      end

      do_cgparam_set(set_cmd, cmd_opts, limits)
    end

    def do_unset_memory(unset_cmd, cmd_opts)
      do_cgparam_unset(
        unset_cmd,
        cmd_opts,
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
      )
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
          v = case field
          when :memory
            t = read_memory_usage(subsystems[:memory], path)
            OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_data(t))

          when :kmemory
            t = read_cgparam(
              subsystems[:memory],
              path,
              'memory.kmem.usage_in_bytes'
            ).to_i
            OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_data(t))

          when :cpu_time
            t = read_cgparam(
              subsystems[:cpuacct],
              path,
              'cpuacct.usage'
            ).to_i
            OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_time_ns(t))

          when :cpu_user_time
            t = read_cgparam(
              subsystems[:cpuacct],
              path,
              'cpuacct.usage_user'
            ).to_i
            OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_time_ns(t))

          when :cpu_sys_time
            t = read_cgparam(
              subsystems[:cpuacct],
              path,
              'cpuacct.usage_sys'
            ).to_i
            OsCtl::Lib::Cli::Presentable.new(t, formatted: precise ? nil : humanize_time_ns(t))

          when :cpu_stat
            Hash[
              read_cgparam(
                subsystems[:cpuacct],
                path,
                'cpuacct.stat'
              ).split("\n").map do |line|
                type, hz = line.split(' ')
                [:"cpu_#{type}_hz", hz.to_i]
              end
            ]

          when :nproc
            read_cgparam(
              subsystems[:pids],
              path,
              'pids.current'
            ).to_i

          else
            nil
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

    # Read and accumulate BlkIO stats
    # @param subsystems [Hash] subsystem => absolute path
    # @param path [String] path of chosen group, relative to the subsystem
    # @param params [Array] parameters to read: `bytes`, `iops`
    def cg_blkio_stats(subsystems, path, params)
      file = {
        bytes: 'blkio.throttle.io_service_bytes',
        iops: 'blkio.throttle.io_serviced',
      }
      ret = {}

      (%i(bytes iops) & params).each do |param|
        r = w = 0

        read_cgparam(subsystems[:blkio], path, file[param]).split("\n").each do |line|
          if /^\d+:\d+ Read (\d+)$/ =~ line
            r += $1.to_i

          elsif /^\d+:\d+ Write (\d+)$/ =~ line
            w += $1.to_i
          end
        end

        ret[param] = {r: r, w: w}
      end

      ret
    end

    # @param memory [String] absolute path to memory subsystem
    # @param path [String] path of chosen group, relative to the subsystem
    # @return [Integer]
    def read_memory_usage(memory, path)
      st = parse_memory_stat(memory, path)
      usage = read_cgparam(memory, path, 'memory.usage_in_bytes').to_i
      usage - st[:total_cache]
    end

    # Add runtime stats from CGroup parameters to `data`
    # @param client [OsCtl::Client]
    # @param data [Hash, Array] hash/array to which the stats are added
    # @param path [String] path of the chosen group
    # @param params [Array] selected stat parameters
    # @param precise [Boolean] humanize parameter values?
    # @return [Hash, Array] data extended with stats
    def cg_add_stats(client, data, path, params, precise)
      subsystems = client.cmd_data!(:group_cgsubsystems)
      fields = CGPARAM_STATS & params

      if data.is_a?(::Hash)
        data.update(cg_read_stats(subsystems, path, fields, precise))
        data

      elsif data.is_a?(::Array)
        data.map do |v|
          v.update(cg_read_stats(subsystems, path.call(v), fields, precise))
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

    def read_cgparam(subsys_path, group_path, param)
      File.read(File.join(subsys_path, group_path, param)).strip
    end
  end
end

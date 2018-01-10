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
              next v if gopts[:parsable] || (!v.is_a?(Integer) && /^\d+$/ !~ v)
              humanize_data(v)
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

    def do_cgparam_set(cmd, cmd_opts)
      cmd_opts.update({
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
        value: args[2..-1].map { |v| parse_data(v) }
      })

      osctld_fmt(cmd, cmd_opts,)
    end

    def do_cgparam_unset(cmd, cmd_opts)
      cmd_opts.update({
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
      })

      osctld_fmt(cmd, cmd_opts)
    end

    def do_cgparam_apply(cmd, cmd_opts)
      osctld_fmt(cmd, cmd_opts)
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
            t = read_cgparam(
              subsystems[:memory],
              path,
              'memory.usage_in_bytes'
            ).to_i
            precise ? t : humanize_data(t)

          when :kmemory
            t = read_cgparam(
              subsystems[:memory],
              path,
              'memory.kmem.usage_in_bytes'
            ).to_i
            precise ? t : humanize_data(t)

          when :cpu_time
            t = read_cgparam(
              subsystems[:cpuacct],
              path,
              'cpuacct.usage'
            ).to_i
            precise ? t : humanize_time_ns(t)

          when :cpu_user_time
            t = read_cgparam(
              subsystems[:cpuacct],
              path,
              'cpuacct.usage_user'
            ).to_i
            precise ? t : humanize_time_ns(t)

          when :cpu_sys_time
            t = read_cgparam(
              subsystems[:cpuacct],
              path,
              'cpuacct.usage_sys'
            ).to_i
            precise ? t : humanize_time_ns(t)

          else
            nil
          end

          next if v.nil?
          ret[field] = v

        rescue Errno::ENOENT
          ret[field] = nil
        end
      end

      ret
    end

    # Add runtime stats from CGroup parameters to `data`
    # @param client [OsCtl::Client]
    # @param data [Hash, Array] hash/array to which the stats are added
    # @param path [String] path of the chosen group
    # @param [Array] selected stat parameters
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

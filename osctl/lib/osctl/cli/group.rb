module OsCtl::Cli
  class Group < Command
    FIELDS = %i(
      name
      path
    )

    DEFAULT_FIELDS = %i(
      name
      path
    )

    PARAM_FIELDS = %i(
      subsystem
      parameter
      value
    )

    PARAM_FILTERS = %i(
      subsystem
    )

    PARAM_DEFAULT_FIELDS = %i(
      parameter
      value
    )

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cmd_opts = {}
      fmt_opts = {layout: :columns}

      cmd_opts[:names] = args if args.count > 0
      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(
        :group_list,
        cmd_opts,
        opts[:output] ? opts[:output].split(',').map(&:to_sym) : DEFAULT_FIELDS,
        fmt_opts
      )
    end

    def show
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      raise "missing argument" unless args[0]

      osctld_fmt(
        :group_show,
        {name: args[0]},
        opts[:output] ? opts[:output].split(',').map(&:to_sym) : nil,
        layout: :rows
      )
    end

    def create
      raise "missing argument" unless args[0]

      cmd_opts = {
        name: args[0],
        path: opts[:path],
        params: parse_cgparams,
      }

      osctld_fmt(:group_create, cmd_opts)
    end

    def delete
      raise "missing argument" unless args[0]
      osctld_fmt(:group_delete, name: args[0])
    end

    def assets
      raise "missing argument" unless args[0]

      osctld_fmt(:group_assets, name: args[0])
    end

    def param_list
      raise "missing argument" unless args[0]

      if opts[:list]
        puts PARAM_FIELDS.join("\n")
        return
      end

      cmd_opts = {name: args[0]}
      fmt_opts = {layout: :columns}

      cmd_opts[:parameters] = args[1..-1] if args.count > 1
      cmd_opts[:subsystem] = opts[:subsystem].split(',') if opts[:subsystem]
      fmt_opts[:header] = false if opts['hide-header']

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : PARAM_DEFAULT_FIELDS

      if i = cols.index(:value)
        cols[i] = {
          name: :value,
          label: 'VALUE',
          align: 'right',
          display: Proc.new do |v|
            next v if gopts[:parsable] || !v.integer?
            humanize(v)
          end
        }
      end

      osctld_fmt(
        :group_param_list,
        cmd_opts,
        cols,
        fmt_opts
      )
    end

    def param_set
      raise "missing group name" unless args[0]
      raise "missing parameter name" unless args[1]
      raise "missing parameter value" unless args[2]

      osctld_fmt(
        :group_param_set,
        name: args[0],
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
        value: parse_value(args[2])
      )
    end

    def param_unset
      raise "missing group name" unless args[0]
      raise "missing parameter name" unless args[1]

      osctld_fmt(
        :group_param_unset,
        name: args[0],
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
      )
    end

    def param_apply
      raise "missing group name" unless args[0]

      osctld_fmt(:group_param_apply, name: args[0])
    end

    protected
    def parse_cgparams
      opts[:param].map do |v|
        parts = v.split('=')

        unless parts.count == 2
          fail "invalid cgparam '#{v}': expected <parameter>=<value>"
        end

        k, v = parts

        {
          subsystem: parse_subsystem(k),
          parameter: k,
          value: parse_value(v),
        }
      end
    end

    def parse_subsystem(param)
      param.split('.').first
    end

    def parse_value(v)
      units = %w(k m g t)

      if /^\d+$/ =~ v
        v.to_i

      elsif /^(\d+)(#{units.join('|')})$/i =~ v
        n = $1.to_i
        i = units.index($2.downcase)

        n * (2 << (9 + (10*i)))

      else
        v
      end
    end

    def humanize(v)
      bits = 39
      units = %i(T G M K)

      units.each do |u|
        threshold = 2 << bits

        return "#{(v / threshold).round(2)}#{u}" if v >= threshold

        bits -= 10
      end

      v.round(2).to_s
    end
  end
end

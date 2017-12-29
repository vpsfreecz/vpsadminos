module OsCtl
  module Cli::CGroupParams
    PARAM_FIELDS = %i(
      subsystem
      parameter
      value
      abs_path
    )

    PARAM_FILTERS = %i(
      subsystem
    )

    PARAM_DEFAULT_FIELDS = %i(
      parameter
      value
    )

    def cgparam_list(cmd, cmd_opts)
      if opts[:list]
        puts PARAM_FIELDS.join("\n")
        return
      end

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
        cmd,
        cmd_opts,
        cols,
        fmt_opts
      )
    end

    def cgparam_set(cmd, cmd_opts)
      cmd_opts.update({
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
        value: parse_value(args[2])
      })

      osctld_fmt(cmd, cmd_opts,)
    end

    def cgparam_unset(cmd, cmd_opts)
      cmd_opts.update({
        subsystem: parse_subsystem(args[1]),
        parameter: args[1],
      })

      osctld_fmt(cmd, cmd_opts)
    end

    def cgparam_apply(cmd, cmd_opts)
      osctld_fmt(cmd, cmd_opts)
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

module OsCtl::Cli
  class Group < Command
    include CGroupParams

    FIELDS = %i(
      name
      path
    ) + CGroupParams::CGPARAM_STATS

    DEFAULT_FIELDS = %i(
      name
      path
      memory
      cpu_time
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
      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : DEFAULT_FIELDS

      c = osctld_open
      groups = cg_add_stats(
        c,
        c.cmd_data!(:group_list, cmd_opts),
        lambda { |g| g[:path] },
        cols,
        gopts[:parsable]
      )
      c.close

      OutputFormatter.print(groups, cols, fmt_opts)
    end

    def show
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      raise "missing argument" unless args[0]

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS

      c = osctld_open
      group = c.cmd_data!(:group_show, name: args[0])
      cg_add_stats(
        c,
        group,
        group[:path],
        cols,
        gopts[:parsable]
      )
      c.close

      OutputFormatter.print(group, cols)
    end

    def create
      raise "missing argument" unless args[0]

      cmd_opts = {
        name: args[0],
        path: opts[:path],
        cgparams: parse_cgparams,
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

    def cgparam_list
      raise "missing argument" unless args[0]

      do_cgparam_list(:group_cgparam_list, name: args[0])
    end

    def cgparam_set
      raise "missing group name" unless args[0]
      raise "missing parameter name" unless args[1]
      raise "missing parameter value" unless args[2]

      do_cgparam_set(:group_cgparam_set, name: args[0])
    end

    def cgparam_unset
      raise "missing group name" unless args[0]
      raise "missing parameter name" unless args[1]

      do_cgparam_unset(:group_cgparam_unset, name: args[0])
    end

    def cgparam_apply
      raise "missing group name" unless args[0]

      do_cgparam_apply(:group_cgparam_apply, name: args[0])
    end
  end
end

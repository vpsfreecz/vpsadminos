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

      osctld_fmt(:group_create, {
        name: args[0],
        path: opts[:path],
      })
    end

    def delete
      raise "missing argument" unless args[0]
      osctld_fmt(:group_delete, name: args[0])
    end

    def assets
      raise "missing argument" unless args[0]

      osctld_fmt(:group_assets, name: args[0])
    end
  end
end

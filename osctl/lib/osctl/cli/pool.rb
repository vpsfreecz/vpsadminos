require 'osctl/cli/command'

module OsCtl::Cli
  class Pool < Command
    FIELDS = %i(
      name
      dataset
      state
      users
      groups
      containers
      parallel_start
      parallel_stop
    )

    DEFAULT_FIELDS = %i(
      name
      dataset
      state
      users
      groups
      containers
    )

    AUTOSTART_FIELDS = %i(
      id
      priority
    )

    include Assets
    include Attributes

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cmd_opts = {}
      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      }

      cmd_opts[:names] = args if args.count > 0
      fmt_opts[:header] = false if opts['hide-header']

      cols =
        if opts[:output] == 'all'
          FIELDS
        elsif opts[:output]
          opts[:output].split(',').map(&:to_sym)
        else
          DEFAULT_FIELDS
        end

      osctld_fmt(:pool_list, cmd_opts, cols, fmt_opts)
    end

    def show
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      require_args!('name')

      cmd_opts = {name: args[0]}
      fmt_opts = {layout: :rows}
      fmt_opts[:header] = false if opts['hide-header']

      cols =
        if opts[:output] == 'all'
          FIELDS
        elsif opts[:output]
          opts[:output].split(',').map(&:to_sym)
        else
          DEFAULT_FIELDS
        end

      osctld_fmt(:pool_show, cmd_opts, cols, fmt_opts)
    end

    def import
      if !args[0] && !opts[:all]
        raise GLI::BadCommandLine, 'specify pool name or --all'
      end

      osctld_fmt(
        :pool_import,
        name: args[0],
        all: opts[:all],
        autostart: opts[:autostart]
      )
    end

    def export
      require_args!('name')
      osctld_fmt(
        :pool_export,
        name: args[0],
        force: opts[:force],
        stop_containers: opts['stop-containers'],
        unregister_users: opts['unregister-users'],
        if_imported: opts['if-imported'],
      )
    end

    def install
      require_args!('name')

      cmd_opts = {name: args[0]}
      cmd_opts[:dataset] = opts[:dataset] if opts[:dataset]

      osctld_fmt(:pool_install, cmd_opts)
    end

    def uninstall
      require_args!('name')
      osctld_fmt(:pool_uninstall, name: args[0])
    end

    def assets
      require_args!('name')

      print_assets(:pool_assets, name: args[0])
    end

    def autostart_queue
      if opts[:list]
        puts AUTOSTART_FIELDS.join("\n")
        return
      end

      require_args!('name')

      fmt_opts = {layout: :columns}
      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(
        :pool_autostart_queue,
        {name: args[0]},
        opts[:output] ? opts[:output].split(',').map(&:to_sym) : nil,
        fmt_opts
      )
    end

    def autostart_trigger
      require_args!('name')
      osctld_fmt(:pool_autostart_trigger, name: args[0])
    end

    def autostart_cancel
      require_args!('name')
      osctld_fmt(:pool_autostart_cancel, name: args[0])
    end

    def set(key)
      require_args!('name', 'n')

      osctld_fmt(:pool_set, name: args[0], key => args[1])
    end

    def unset(key)
      require_args!('name')

      osctld_fmt(:pool_unset, name: args[0], options: [key])
    end

    def set_attr
      require_args!('name', 'attribute', 'value')
      do_set_attr(
        :pool_set,
        {name: args[0]},
        args[1],
        args[2],
      )
    end

    def unset_attr
      require_args!('name', 'attribute')
      do_unset_attr(
        :pool_unset,
        {name: args[0]},
        args[1],
      )
    end
  end
end

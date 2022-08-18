require 'osctl/cli/command'
require 'osctl/cli/assets'

module OsCtl::Cli
  class User < Command
    include Assets
    include Attributes

    FIELDS = %i(
      pool
      name
      username
      groupname
      ugid
      dataset
      homedir
      registered
      standalone
    )

    FILTERS = %i(pool registered)

    DEFAULT_FIELDS = %i(
      pool
      name
      registered
      standalone
    )

    IDMAP_FIELDS = %i(type ns_id host_id count)

    def list
      keyring = KernelKeyring.new

      if opts[:list]
        puts (FIELDS + keyring.list_param_names).join("\n")
        return
      end

      cmd_opts = {}
      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      }

      cmd_opts[:names] = args if args.count > 0

      if opts[:registered]
        cmd_opts[:registered] = true
      elsif opts[:unregistered]
        cmd_opts[:registered] = false
      end

      FILTERS.each do |v|
        [gopts, opts].each do |options|
          next unless options[v]
          cmd_opts[v] = options[v].split(',')
        end
      end

      fmt_opts[:header] = false if opts['hide-header']

      cols =
        if opts[:output] == 'all'
          FIELDS
        elsif opts[:output]
          opts[:output].split(',').map(&:to_sym)
        else
          DEFAULT_FIELDS
        end

      users = osctld_call(:user_list, **cmd_opts)
      keyring.add_user_values(users, cols, precise: gopts[:parsable])

      format_output(users, cols, **fmt_opts)
    end

    def show
      keyring = KernelKeyring.new

      if opts[:list]
        puts (FIELDS + keyring.list_param_names).join("\n")
        return
      end

      require_args!('name')

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

      user = osctld_call(:user_show, {name: args[0], pool: gopts[:pool]})
      keyring.add_user_values(user, cols, precise: gopts[:parsable])

      format_output(user, cols, **fmt_opts)
    end

    def create
      require_args!('name')

      if opts['map'].any?
        uid_map = gid_map = opts['map']

      else
        uid_map = opts['map-uid']
        gid_map = opts['map-gid']
      end

      osctld_fmt(:user_create, cmd_opts: {
        name: args[0],
        pool: opts[:pool] || gopts[:pool],
        id_range: opts['id-range'],
        block_index: opts['id-range-block-index'],
        uid_map: uid_map.any? ? uid_map : nil,
        gid_map: gid_map.any? ? gid_map : nil,
        standalone: opts['standalone'],
      })
    end

    def delete
      require_args!('name')
      osctld_fmt(:user_delete, cmd_opts: {name: args[0], pool: gopts[:pool]})
    end

    def register
      require_args!('name')

      if args[0] == 'all'
        osctld_fmt(:user_register, cmd_opts: {all: true})
      else
        osctld_fmt(:user_register, cmd_opts: {name: args[0], pool: gopts[:pool]})
      end
    end

    def unregister
      require_args!('name')

      if args[0] == 'all'
        osctld_fmt(:user_unregister, cmd_opts: {all: true})
      else
        osctld_fmt(:user_unregister, cmd_opts: {name: args[0], pool: gopts[:pool]})
      end
    end

    def subugids
      osctld_fmt(:user_subugids)
    end

    def assets
      require_args!('name')
      print_assets(:user_assets, name: args[0], pool: gopts[:pool])
    end

    def idmap_ls
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      require_args!('name', optional: %w(type))

      cmd_opts = {name: args[0], uid: true, gid: true}
      fmt_opts = {layout: :columns}

      case args[1]
      when 'uid'
        cmd_opts[:gid] = false
      when 'gid'
        cmd_opts[:uid] = false
      when nil, 'both'
        # pass
      else
        raise GLI::BadCommandLine, "expected uid|gid|both, got '#{args[1]}'"
      end

      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(
        :user_idmap_list,
        cmd_opts: cmd_opts,
        cols: opts[:output] ? opts[:output].split(',').map(&:to_sym) : IDMAP_FIELDS,
        fmt_opts: fmt_opts,
      )
    end

    def set_standalone
      require_args!('name')
      osctld_fmt(:user_set, cmd_opts: {
        name: args[0],
        pool: gopts[:pool],
        standalone: true,
      })
    end

    def unset_standalone
      require_args!('name')
      osctld_fmt(:user_unset, cmd_opts: {
        name: args[0],
        pool: gopts[:pool],
        standalone: true,
      })
    end

    def set_attr
      require_args!('name', 'attribute', 'value')
      do_set_attr(
        :user_set,
        {name: args[0], pool: gopts[:pool]},
        args[1],
        args[2],
      )
    end

    def unset_attr
      require_args!('name', 'attribute')
      do_unset_attr(
        :user_unset,
        {name: args[0], pool: gopts[:pool]},
        args[1],
      )
    end
  end
end

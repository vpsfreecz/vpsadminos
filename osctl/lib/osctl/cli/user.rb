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
    )

    FILTERS = %i(pool registered)

    DEFAULT_FIELDS = %i(
      pool
      name
      registered
    )

    IDMAP_FIELDS = %i(type ns_id host_id count)

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

      osctld_fmt(
        :user_list,
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

      require_args!('name')

      fmt_opts = {layout: :rows}
      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(
        :user_show,
        {name: args[0], pool: gopts[:pool]},
        opts[:output] ? opts[:output].split(',').map(&:to_sym) : nil,
        fmt_opts
      )
    end

    def create
      require_args!('name')

      if opts['map'].any? && (opts['map-uid'].any? || opts['map-gid'].any?)
        raise GLI::BadCommandLine, 'use either --map, or --map-uid and --map-gid'

      elsif (opts['map'] + opts['map-uid']).empty?
        raise GLI::BadCommandLine, 'provide at least one UID mapping with --map '+
          'or --map-uid'

      elsif (opts['map'] + opts['map-gid']).empty?
        raise GLI::BadCommandLine, 'provide at least one GID mapping with --map '+
          'or --map-gid'
      end

      if opts['map'].any?
        uid_map = gid_map = opts['map']

      else
        uid_map = opts['map-uid']
        gid_map = opts['map-gid']
      end

      osctld_fmt(:user_create, {
        name: args[0],
        pool: opts[:pool] || gopts[:pool],
        type: opts[:ugid] ? 'static' : 'dynamic',
        ugid: opts[:ugid],
        uid_map: uid_map,
        gid_map: gid_map,
      })
    end

    def delete
      require_args!('name')
      osctld_fmt(:user_delete, name: args[0], pool: gopts[:pool])
    end

    def register
      require_args!('name')

      if args[0] == 'all'
        osctld_fmt(:user_register, all: true)
      else
        osctld_fmt(:user_register, name: args[0], pool: gopts[:pool])
      end
    end

    def unregister
      require_args!('name')

      if args[0] == 'all'
        osctld_fmt(:user_unregister, all: true)
      else
        osctld_fmt(:user_unregister, name: args[0], pool: gopts[:pool])
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

      require_args!('name')

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
        cmd_opts,
        opts[:output] ? opts[:output].split(',').map(&:to_sym) : IDMAP_FIELDS,
        fmt_opts
      )
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

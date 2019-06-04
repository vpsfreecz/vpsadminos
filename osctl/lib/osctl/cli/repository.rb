require 'osctl/cli/command'

module OsCtl::Cli
  class Repository < Command
    include Assets
    include Attributes

    FIELDS = %i(pool name url enabled)
    IMAGE_FIELDS = %i(vendor variant arch distribution version tags cached)
    IMAGE_FILTERS = %i(vendor variant arch distribution version tag cached)

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cmd_opts = {pool: gopts[:pool]}
      fmt_opts = {layout: :columns}

      cmd_opts[:names] = args if args.count > 0

      fmt_opts[:header] = false if opts['hide-header']
      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS

      osctld_fmt(:repo_list, cmd_opts, cols, fmt_opts)
    end

    def show
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      require_args!('name')

      cmd_opts = {name: args[0], pool: gopts[:pool]}
      fmt_opts = {layout: :rows}

      fmt_opts[:header] = false if opts['hide-header']
      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS

      osctld_fmt(:repo_show, cmd_opts, cols, fmt_opts)
    end

    def add
      require_args!('name', 'url')
      osctld_fmt(:repo_add, pool: gopts[:pool], name: args[0], url: args[1])
    end

    def delete
      require_args!('name')
      osctld_fmt(:repo_delete, pool: gopts[:pool], name: args[0])
    end

    def enable
      require_args!('name')
      osctld_fmt(:repo_enable, pool: gopts[:pool], name: args[0])
    end

    def disable
      require_args!('name')
      osctld_fmt(:repo_disable, pool: gopts[:pool], name: args[0])
    end

    def set_url
      require_args!('name', 'url')
      osctld_fmt(:repo_set, name: args[0], pool: gopts[:pool], url: args[1])
    end

    def set_attr
      require_args!('name', 'attribute', 'value')
      do_set_attr(
        :repo_set,
        {name: args[0], pool: gopts[:pool]},
        args[1],
        args[2],
      )
    end

    def unset_attr
      require_args!('name', 'attribute')
      do_unset_attr(
        :repo_unset,
        {name: args[0], pool: gopts[:pool]},
        args[1],
      )
    end

    def assets
      require_args!('name')
      print_assets(:repo_assets, name: args[0], pool: gopts[:pool])
    end

    def image_list
      if opts[:list]
        puts IMAGE_FIELDS.join("\n")
        return
      end

      require_args!('name')

      cmd_opts = {pool: gopts[:pool], name: args[0]}

      IMAGE_FILTERS.each do |v|
        cmd_opts[v] = opts[v] if opts[v]
      end

      cmd_opts[:cached] = true if opts[:cached]
      cmd_opts[:cached] = false if opts[:uncached]

      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      }
      fmt_opts[:header] = false if opts['hide-header']
      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : IMAGE_FIELDS

      if i = cols.index(:tags)
        cols[i] = {
          name: :tags,
          label: 'TAGS',
          align: 'left',
          display: Proc.new { |values| values.join(',') },
        }
      end

      osctld_fmt(:repo_image_list, cmd_opts, cols, fmt_opts)
    end
  end
end

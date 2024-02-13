require 'osctl/cli/command'

module OsCtl::Cli
  class Repository < Command
    include Assets
    include Attributes

    FIELDS = %i[pool name url enabled]
    IMAGE_FIELDS = %i[vendor variant arch distribution version tags cached]
    IMAGE_FILTERS = %i[vendor variant arch distribution version tag cached]

    def list
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      cmd_opts = { pool: gopts[:pool] }
      fmt_opts = {
        layout: :columns,
        cols: param_selector.parse_option(opts[:output])
      }

      cmd_opts[:names] = args if args.count > 0

      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(:repo_list, cmd_opts:, fmt_opts:)
    end

    def show
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('name')

      cmd_opts = { name: args[0], pool: gopts[:pool] }
      fmt_opts = {
        layout: :rows,
        cols: param_selector.parse_option(opts[:output])
      }

      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(:repo_show, cmd_opts:, fmt_opts:)
    end

    def add
      require_args!('name', 'url')
      osctld_fmt(:repo_add, cmd_opts: { pool: gopts[:pool], name: args[0], url: args[1] })
    end

    def delete
      require_args!('name')
      osctld_fmt(:repo_delete, cmd_opts: { pool: gopts[:pool], name: args[0] })
    end

    def enable
      require_args!('name')
      osctld_fmt(:repo_enable, cmd_opts: { pool: gopts[:pool], name: args[0] })
    end

    def disable
      require_args!('name')
      osctld_fmt(:repo_disable, cmd_opts: { pool: gopts[:pool], name: args[0] })
    end

    def set_url
      require_args!('name', 'url')
      osctld_fmt(:repo_set, cmd_opts: { name: args[0], pool: gopts[:pool], url: args[1] })
    end

    def set_attr
      require_args!('name', 'attribute', 'value')
      do_set_attr(
        :repo_set,
        { name: args[0], pool: gopts[:pool] },
        args[1],
        args[2]
      )
    end

    def unset_attr
      require_args!('name', 'attribute')
      do_unset_attr(
        :repo_unset,
        { name: args[0], pool: gopts[:pool] },
        args[1]
      )
    end

    def assets
      require_args!('name')
      print_assets(:repo_assets, name: args[0], pool: gopts[:pool])
    end

    def image_list
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: IMAGE_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('name')

      cmd_opts = { pool: gopts[:pool], name: args[0] }

      IMAGE_FILTERS.each do |v|
        cmd_opts[v] = opts[v] if opts[v]
      end

      cmd_opts[:cached] = true if opts[:cached]
      cmd_opts[:cached] = false if opts[:uncached]

      fmt_opts = {
        layout: :columns,
        cols: param_selector.parse_option(opts[:output]),
        sort: opts[:sort] && param_selector.parse_option(opts[:sort]),
        opts: {
          tags: {
            label: 'TAGS',
            align: 'left',
            display: proc { |values| values.join(',') }
          }
        }
      }
      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(:repo_image_list, cmd_opts:, fmt_opts:)
    end
  end
end

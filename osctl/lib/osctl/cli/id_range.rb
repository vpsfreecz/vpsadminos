require 'osctl/cli/command'

module OsCtl::Cli
  class IdRange < Command
    include Assets
    include Attributes

    FIELDS = %i[pool name start_id last_id block_size block_count allocated free]

    TABLE_FIELDS = %i[type block_index block_count owner first_id last_id id_count]

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
        cols: param_selector.parse_option(opts[:output]),
        sort: opts[:sort] && param_selector.parse_option(opts[:sort])
      }

      cmd_opts[:names] = args if args.count > 0

      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(:id_range_list, cmd_opts:, fmt_opts:)
    end

    def show
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('id-range')

      cmd_opts = { name: args[0], pool: gopts[:pool] }
      fmt_opts = {
        layout: :rows,
        cols: param_selector.parse_option(opts[:output])
      }

      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(:id_range_show, cmd_opts:, fmt_opts:)
    end

    def create
      require_args!('id-range')

      osctld_fmt(:id_range_create, cmd_opts: {
        pool: gopts[:pool],
        name: args[0],
        start_id: opts['start-id'],
        block_size: opts['block-size'],
        block_count: opts['block-count']
      })
    end

    def delete
      require_args!('id-range')

      osctld_fmt(:id_range_delete, cmd_opts: {
        pool: gopts[:pool],
        name: args[0]
      })
    end

    def table_list
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: TABLE_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('id-range', optional: %w[type])

      types = %w[all allocated free]

      if args[1] && !types.include?(args[1])
        raise GLI::BadCommandLine, "type can be one of: #{types.join(', ')}"
      end

      cmd_opts = {
        pool: gopts[:pool],
        name: args[0],
        type: args[1] || 'all'
      }
      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym)
      }

      fmt_opts[:header] = false if opts['hide-header']
      fmt_opts[:cols] = param_selector.parse_option(opts[:output])

      osctld_fmt(:id_range_table_list, cmd_opts:, fmt_opts:)
    end

    def table_show
      param_selector = OsCtl::Lib::Cli::ParameterSelector.new(
        all_params: TABLE_FIELDS
      )

      if opts[:list]
        puts param_selector
        return
      end

      require_args!('id-range', 'block-index')

      cmd_opts = { name: args[0], pool: gopts[:pool], block_index: args[1].to_i }
      fmt_opts = {
        layout: :rows,
        cols: param_selector.parse_option(opts[:output])
      }

      fmt_opts[:header] = false if opts['hide-header']

      osctld_fmt(:id_range_table_show, cmd_opts:, fmt_opts:)
    end

    def allocate
      require_args!('id-range')

      osctld_fmt(:id_range_allocate, cmd_opts: {
        pool: gopts[:pool],
        name: args[0],
        block_count: opts['block-count'],
        block_index: opts['block-index'],
        owner: opts[:owner]
      })
    end

    def free
      require_args!('id-range')

      if !opts['block-index'] === !opts['owner']
        raise GLI::BadCommandLine, 'use --block-index or --owner'
      end

      osctld_fmt(:id_range_free, cmd_opts: {
        pool: gopts[:pool],
        name: args[0],
        block_index: opts['block-index'],
        owner: opts['owner']
      })
    end

    def set_attr
      require_args!('id-range', 'attribute', 'value')
      do_set_attr(
        :id_range_set,
        { name: args[0], pool: gopts[:pool] },
        args[1],
        args[2]
      )
    end

    def unset_attr
      require_args!('id-range', 'attribute')
      do_unset_attr(
        :id_range_unset,
        { name: args[0], pool: gopts[:pool] },
        args[1]
      )
    end

    def assets
      require_args!('name')
      print_assets(:id_range_assets, name: args[0], pool: gopts[:pool])
    end
  end
end

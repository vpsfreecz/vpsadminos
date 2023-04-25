require 'osctl/cli/command'
require 'osctl/cli/cgroup_params'
require 'osctl/cli/devices'
require 'osctl/cli/assets'

module OsCtl::Cli
  class Group < Command
    include CGroupParams
    include Devices
    include Assets
    include Attributes

    FIELDS = %i(
      pool
      name
      path
      full_path
    ) + CGroupParams::CGPARAM_STATS

    FILTERS = %i(
      pool
    )

    DEFAULT_FIELDS = %i(
      pool
      name
      memory
      cpu_us
    )

    def list
      c = osctld_open
      cg_init_subsystems(c)

      cgparams = cg_list_raw_cgroup_params

      if opts[:list]
        puts (FIELDS + cgparams).join("\n")
        return
      end

      cmd_opts = {}
      fmt_opts = {
        layout: :columns,
        sort: opts[:sort] && opts[:sort].split(',').map(&:to_sym),
      }

      cmd_opts[:names] = args if args.count > 0

      FILTERS.each do |v|
        [gopts, opts].each do |options|
          next unless options[v]
          cmd_opts[v] = options[v].split(',')
        end
      end

      fmt_opts[:header] = false if opts['hide-header']

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : DEFAULT_FIELDS
      fmt_opts[:cols] = cols

      groups = cg_add_stats(
        c.cmd_data!(:group_list, **cmd_opts),
        lambda { |g| g[:full_path] },
        cols,
        gopts[:parsable]
      )
      c.close

      cg_add_raw_cgroup_params(
        groups,
        lambda { |g| g[:full_path] },
        cols & cgparams.map(&:to_sym)
      )

      format_output(groups, **fmt_opts)
    end

    def tree
      require_args!('pool')
      Tree.print(args[0], parsable: gopts[:parsable], color: gopts[:color])
    end

    def show
      c = osctld_open
      cg_init_subsystems(c)

      cgparams = cg_list_raw_cgroup_params

      if opts[:list]
        puts (FIELDS + cgparams).join("\n")
        return
      end

      require_args!('name')

      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : FIELDS

      fmt_opts = {
        layout: :rows,
        cols: cols,
      }
      fmt_opts[:header] = false if opts['hide-header']

      group = c.cmd_data!(:group_show, name: args[0], pool: gopts[:pool])
      cg_add_stats(
        group,
        group[:full_path],
        cols,
        gopts[:parsable]
      )
      c.close

      cg_add_raw_cgroup_params(
        group,
        group[:full_path],
        cols & cgparams.map(&:to_sym)
      )

      format_output(group, **fmt_opts)
    end

    def create
      require_args!('name')

      cmd_opts = {
        name: args[0],
        pool: opts[:pool] || gopts[:pool],
        parents: opts[:parents],
        cgparams: parse_cgparams,
      }

      osctld_fmt(:group_create, cmd_opts: cmd_opts)
    end

    def delete
      require_args!('name')
      osctld_fmt(:group_delete, cmd_opts: {name: args[0], pool: gopts[:pool]})
    end

    def set_cpu_limit
      require_args!('name', 'limit')
      do_set_cpu_limit(:group_cgparam_set, name: args[0], pool: gopts[:pool])
    end

    def unset_cpu_limit
      require_args!('name')
      do_unset_cpu_limit(
        :group_cgparam_unset,
        name: args[0],
        pool: gopts[:pool]
      )
    end

    def set_memory_limit
      require_args!('name', 'memory', optional: %w(swap))
      do_set_memory(
        :group_cgparam_set,
        :group_cgparam_unset,
        name: args[0],
        pool: gopts[:pool]
      )
    end

    def unset_memory_limit
      require_args!('name')
      do_unset_memory(
        :group_cgparam_unset,
        name: args[0],
        pool: gopts[:pool]
      )
    end

    def set_attr
      require_args!('name', 'attribute', 'value')
      do_set_attr(
        :group_set,
        {name: args[0], pool: gopts[:pool]},
        args[1],
        args[2],
      )
    end

    def unset_attr
      require_args!('name', 'attribute')
      do_unset_attr(
        :group_unset,
        {name: args[0], pool: gopts[:pool]},
        args[1],
      )
    end

    def assets
      require_args!('name')
      print_assets(:group_assets, name: args[0], pool: gopts[:pool])
    end

    def cgparam_list
      require_args!('name', strict: false)
      do_cgparam_list(:group_cgparam_list, name: args[0], pool: gopts[:pool])
    end

    def cgparam_set
      require_args!('name', 'parameter', 'value', strict: false)
      do_cgparam_set(:group_cgparam_set, name: args[0], pool: gopts[:pool])
    end

    def cgparam_unset
      require_args!('name', 'parameter')
      do_cgparam_unset(:group_cgparam_unset, name: args[0], pool: gopts[:pool])
    end

    def cgparam_apply
      require_args!('name')
      do_cgparam_apply(:group_cgparam_apply, name: args[0], pool: gopts[:pool])
    end

    def cgparam_replace
      require_args!('name')
      do_cgparam_replace(:group_cgparam_replace, name: args[0], pool: gopts[:pool])
    end

    def device_list
      require_args!('name')
      do_device_list(:group_device_list, name: args[0], pool: gopts[:pool])
    end

    def device_add
      require_args!('name', 'type', 'major', 'minor', 'mode', optional: %w(device))
      do_device_add(:group_device_add, name: args[0], pool: gopts[:pool])
    end

    def device_delete
      require_args!('name', 'type', 'major', 'minor')
      do_device_delete(:group_device_delete, name: args[0], pool: gopts[:pool])
    end

    def device_chmod
      require_args!('name', 'type', 'major', 'minor', 'mode')
      do_device_chmod(:group_device_chmod, name: args[0], pool: gopts[:pool])
    end

    def device_promote
      require_args!('name', 'type', 'major', 'minor')
      do_device_chmod(:group_device_promote, name: args[0], pool: gopts[:pool])
    end

    def device_inherit
      require_args!('name', 'type', 'major', 'minor')
      do_device_inherit(:group_device_inherit, name: args[0], pool: gopts[:pool])
    end

    def device_set_inherit
      require_args!('name', 'type', 'major', 'minor')
      do_device_set_inherit(:group_device_set_inherit, name: args[0], pool: gopts[:pool])
    end

    def device_unset_inherit
      require_args!('name', 'type', 'major', 'minor')
      do_device_unset_inherit(:group_device_unset_inherit, name: args[0], pool: gopts[:pool])
    end

    def device_replace
      require_args!('name')
      do_device_replace(:group_device_replace, name: args[0], pool: gopts[:pool])
    end
  end
end

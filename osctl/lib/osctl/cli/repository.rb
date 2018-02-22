module OsCtl::Cli
  class Repository < Command
    include Assets

    FIELDS = %i(pool name url enabled)

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cmd_opts = {pool: gopts[:pool]}
      fmt_opts = {layout: :columns}

      fmt_opts[:header] = false if opts['hide-header']
      cols = opts[:output] ? opts[:output].split(',').map(&:to_sym) : nil

      osctld_fmt(:repo_list, cmd_opts, cols, fmt_opts)
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

    def assets
      require_args!('name')
      print_assets(:repo_assets, name: args[0], pool: gopts[:pool])
    end
  end
end

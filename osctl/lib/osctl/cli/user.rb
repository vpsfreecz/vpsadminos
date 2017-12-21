module OsCtl::Cli
  class User < Command
    FIELDS = %i(
      name
      username
      groupname
      ugid
      ugid_offset
      ugid_size
      dataset
      homedir
      registered
    )

    FILTERS = %i(registered)

    DEFAULT_FIELDS = %i(
      name
      registered
    )

    def list
      if opts[:list]
        puts FIELDS.join("\n")
        return
      end

      cmd_opts = {}
      fmt_opts = {layout: :columns}

      cmd_opts[:names] = args if args.count > 0

      if opts[:registered]
        cmd_opts[:registered] = true
      elsif opts[:unregistered]
        cmd_opts[:registered] = false
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

      raise "missing argument" unless args[0]

      osctld_fmt(
        :user_show,
        {name: args[0]},
        opts[:output] ? opts[:output].split(',').map(&:to_sym) : nil,
        layout: :rows
      )
    end

    def create
      raise "missing argument" unless args[0]

      osctld_fmt(:user_create, {
        name: args[0],
        ugid: opts[:ugid],
        offset: opts[:offset],
        size: opts[:size],
      })
    end

    def delete
      raise "missing argument" unless args[0]
      osctld_fmt(:user_delete, name: args[0])
    end

    def su
      raise "missing argument" unless args[0]

      # TODO: error handling
      cmd = osctld(:user_su, name: args[0])[:response]
      pid = Process.fork do
        cmd[:env].each do |k, v|
          ENV[k.to_s] = v
        end

        Process.exec(*cmd[:cmd])
      end

      Process.wait(pid)
    end

    def register
      raise "missing argument" unless args[0]

      if args[0] == 'all'
        osctld_fmt(:user_register, all: true)
      else
        osctld_fmt(:user_register, name: args[0])
      end
    end

    def unregister
      raise "missing argument" unless args[0]

      if args[0] == 'all'
        osctld_fmt(:user_unregister, all: true)
      else
        osctld_fmt(:user_unregister, name: args[0])
      end
    end

    def subugids
      osctld_fmt(:user_subugids)
    end

    def assets
      raise "missing argument" unless args[0]

      osctld_fmt(:user_assets, name: args[0])
    end
  end
end

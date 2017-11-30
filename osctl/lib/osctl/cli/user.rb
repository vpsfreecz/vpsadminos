require 'bundler'

module OsCtl::Cli
  class User < Command
    def list
      osctld_fmt(:user_list)
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
      cmd = osctld(:user_su, name: args[0])[:response][:cmd]
      pid = Process.fork { Bundler.clean_exec(*cmd) }

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
  end
end

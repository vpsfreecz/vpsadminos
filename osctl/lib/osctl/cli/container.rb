require 'bundler'

module OsCtl::Cli
  class Container < Command
    def list
      osctld_fmt(:ct_list)
    end

    def create
      raise "missing argument" unless args[0]

      osctld_fmt(
        :ct_create,
        id: args[0],
        user: opts[:user],
        template: File.absolute_path(opts[:template]),
      )
    end

    def delete
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_delete, id: args[0])
    end

    def start
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_start, id: args[0])
    end

    def stop
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_stop, id: args[0])
    end

    def restart
      raise "missing argument" unless args[0]

      osctld_fmt(:ct_restart, id: args[0])
    end

    def attach
      raise "missing argument" unless args[0]

      # TODO: error handling
      cmd = osctld(:ct_attach, id: args[0])[:response][:cmd]
      pid = Process.fork { Bundler.clean_exec(*cmd) }

      Process.wait(pid)
    end

    def su
      raise "missing argument" unless args[0]

      # TODO: error handling
      ret = osctld(:ct_su, id: args[0])
      cmd = ret[:response][:cmd]
      pid = Process.fork { Bundler.clean_exec(*cmd) }

      Process.wait(pid)
    end
  end
end

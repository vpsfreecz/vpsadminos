require 'osctld/commands/base'

module OsCtld
  class Commands::Container::Passwd < Commands::Base
    handle :ct_passwd

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        ret = DistConfig.run(
          ct,
          :passwd,
          user: opts[:user],
          password: opts[:password]
        )

        if ret
          ok
        else
          error("unable to set password for #{opts[:user]}")
        end
      end
    end
  end
end

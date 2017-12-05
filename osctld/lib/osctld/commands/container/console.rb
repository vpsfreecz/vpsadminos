module OsCtld
  class Commands::Container::Console < Commands::Base
    handle :ct_console

    include Utils::Log
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ct.inclusively do
        next error('container not running') if ct.state != :running

        ok(user_exec(
          ct.user,
          'lxc-console', '-P', ct.user.lxc_home,
          '-t', opts[:tty], '-n', ct.id
        ))
      end
    end
  end
end

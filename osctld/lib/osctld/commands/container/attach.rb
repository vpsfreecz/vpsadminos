module OsCtld
  class Commands::Container::Attach < Commands::Base
    handle :ct_attach

    include Utils::Log
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ct.inclusively do
        next error('container not running') if ct.state != :running

        ok(user_exec(
          ct.user,
          'lxc-attach', '-P', ct.user.lxc_home,
          '--clear-env', '--keep-var', 'TERM',
          '-n', ct.id
        ))
      end
    end
  end
end

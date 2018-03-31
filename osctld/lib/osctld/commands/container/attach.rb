module OsCtld
  class Commands::Container::Attach < Commands::Base
    handle :ct_attach

    include OsCtl::Lib::Utils::Log
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id], opts[:pool])
      return error('container not found') unless ct

      ct.inclusively do
        next error('container not running') if ct.state != :running

        ok(ct_exec(
          ct,
          'lxc-attach', '-P', ct.lxc_home,
          '--clear-env', '--keep-var', 'TERM',
          '-v', 'USER=root',
          '-v', 'LOGNAME=root',
          '-v', 'HOME=/root',
          '-n', ct.id
        ))
      end
    end
  end
end

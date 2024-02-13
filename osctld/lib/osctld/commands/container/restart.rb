require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Restart < Commands::Logged
    handle :ct_restart

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        if opts[:reboot]
          begin
            ContainerControl::Commands::Reboot.run!(ct)
            ok
          rescue ContainerControl::Error => e
            error!(e.message)
          end

        else
          call_cmd!(
            Commands::Container::Stop,
            pool: ct.pool.name,
            id: ct.id,
            timeout: opts[:stop_timeout],
            method: opts[:stop_method],
            message: opts[:message]
          )
          call_cmd!(
            Commands::Container::Start,
            pool: ct.pool.name,
            id: ct.id,
            force: true,
            wait: opts[:wait]
          )
        end
      end
    end
  end
end

require 'osctld/commands/logged'

module OsCtld
  class Commands::Container::Stop < Commands::Logged
    handle :ct_stop

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      manipulate(ct) do
        progress('Stopping container')

        case (opts[:method] || 'shutdown_or_kill')
        when 'shutdown_or_kill'
          cmd = :ct_stop

        when 'shutdown_or_fail'
          cmd = :ct_shutdown

        when 'kill'
          cmd = :ct_kill

        else
          error!("unknown stop method '#{opts[:method]}'")
        end

        begin
          Container::Hook.run(ct, :pre_stop)

        rescue HookFailed => e
          error!(e.message)
        end

        ret = ct_control(ct, cmd, id: ct.id, timeout: opts[:timeout] || 60)
        next ret unless ret[:status]

        if ct.ephemeral? && !indirect?
          call_cmd!(
            Commands::Container::Delete,
            pool: ct.pool.name,
            id: ct.id,
            force: true,
          )
        end

        ok
      end
    end
  end
end

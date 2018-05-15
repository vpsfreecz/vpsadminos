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
      ct.exclusively do
        progress('Stopping container') if opts[:progress].nil? || opts[:progress]

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

        Console.tty0_pipes(ct).each do |pipe|
          File.unlink(pipe) if File.exist?(pipe)
        end

        ok
      end
    end
  end
end

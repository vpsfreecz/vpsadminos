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
        ret = ct_control(ct, :ct_stop, id: ct.id)
        next ret unless ret[:status]

        Console.tty0_pipes(ct).each do |pipe|
          File.unlink(pipe) if File.exist?(pipe)
        end

        ok
      end
    end
  end
end

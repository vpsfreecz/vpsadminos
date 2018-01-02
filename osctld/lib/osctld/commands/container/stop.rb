module OsCtld
  class Commands::Container::Stop < Commands::Base
    handle :ct_stop

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = DB::Containers.find(opts[:id]) || (raise 'container not found')
      ct.exclusively do
        ret = ct_control(ct, :ct_stop, id: ct.id)
        next ret unless ret[:status]

        Console.tty0_pipes(ct.id).each do |pipe|
          File.unlink(pipe) if File.exist?(pipe)
        end

        ok
      end
    end
  end
end

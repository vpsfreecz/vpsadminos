module OsCtld
  class Commands::Container::Start < Commands::Base
    handle :ct_start

    include Utils::Log
    include Utils::System
    include Utils::SwitchUser

    def execute
      ct = ContainerList.find(opts[:id]) || (raise 'container not found')
      ct.exclusively do
        ct_control(ct.user, :ct_start, id: ct.id)
      end
    end
  end
end

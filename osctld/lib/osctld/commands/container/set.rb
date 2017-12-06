module OsCtld
  class Commands::Container::Set < Commands::Base
    handle :ct_set

    include Utils::Log
    include Utils::System

    def execute
      ct = ContainerList.find(opts[:id])
      return error('container not found') unless ct

      ct.exclusively do
        if opts[:route_via]
          if ct.state != :stopped
            next error('stop the container to change routing')
          end

          ct.set_route_via(
            Hash[ opts[:route_via].map { |k,v| [k.to_s.to_i, v] } ]
          )
          Script::Container::Network.run(ct)
        end

        ok
      end
    end
  end
end

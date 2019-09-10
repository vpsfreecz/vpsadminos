require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Attach to the server's namespaces and run shell
  class Operations::Server::Attach < Operations::Base
    # @param name [String]
    def initialize(name)
      @server = Server.new(name)
    end

    def execute
      Operations::Server::Exec.run(server) do
        ENV['PS1'] = "[NFSD #{server.name}]# "
        Process.exec('/usr/bin/env', 'bash', '--norc')
      end
    end

    protected
    attr_reader :server
  end
end

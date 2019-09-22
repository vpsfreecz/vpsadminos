require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Attach to the server's namespaces and run shell
  class Operations::Server::Attach < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param name [String]
    def initialize(name)
      @server = Server.new(name)
    end

    def execute
      bin_bash = File.join(bash_interactive, 'bin/bash')

      Operations::Server::Exec.run(server) do
        ENV['PATH'] = "#{ENV['PATH']}:/run/current-system/sw/bin"
        ENV['PS1'] = "[NFSD #{server.name}]# "
        Process.exec(bin_bash, '--norc')
      end
    end

    protected
    attr_reader :server

    def bash_interactive
      syscmd("nix-build --no-out-link '<nixpkgs>'  -A bashInteractive").output.strip
    end
  end
end

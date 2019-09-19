require 'osctl/exportfs/cli/command'

module OsCtl::ExportFS::Cli
  class Server < Command
    def list
      puts sprintf('%-20s %s', 'SERVER', 'STATE')

      OsCtl::ExportFS::Operations::Server::List.run.each do |s|
        puts sprintf('%-20s %s', s.name, s.running? ? 'running' : 'stopped')
      end
    end

    def create
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Create.run(
        args[0],
        address: opts[:address],
        netif: opts[:netif],
      )
    end

    def delete
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Delete.run(args[0])
    end

    def start
      require_args!('name')
      runsv = OsCtl::ExportFS::Operations::Server::Runsv.new(args[0])
      runsv.start(
        address: opts[:address],
        netif: opts[:netif],
      )
    end

    def stop
      require_args!('name')
      runsv = OsCtl::ExportFS::Operations::Server::Runsv.new(args[0])
      runsv.stop
    end

    def restart
      require_args!('name')
      runsv = OsCtl::ExportFS::Operations::Server::Runsv.new(args[0])
      runsv.restart(
        address: opts[:address],
        netif: opts[:netif],
      )
    end

    def spawn
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Spawn.run(
        args[0],
        address: opts[:address],
        netif: opts[:netif],
      )
    end

    def attach
      require_args!('name')
      OsCtl::ExportFS::Operations::Server::Attach.run(args[0])
    end
  end
end

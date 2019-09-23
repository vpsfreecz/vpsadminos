require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  class Operations::Server::CGroup < Operations::Base
    CONTROLLER = 'systemd'
    PATH = 'osctl/exportfs/server'

    # @param server [Server]
    def initialize(server)
      @server = server
      @cgroup = OsCtl::ExportFS::CGroup.new(CONTROLLER, PATH)
    end

    def enter_manager
      cgroup.create(path)
      cgroup.enter(path)
    end

    def enter_payload
      cgroup.create(payload_path)
      cgroup.enter(payload_path)
    end

    def clear_payload
      cgroup.kill_all_until_empty(payload_path)
      cgroup.destroy(payload_path)
    end

    protected
    attr_reader :server, :cgroup

    def path
      server.name
    end

    def payload_path
      File.join(server.name, 'payload')
    end
  end
end

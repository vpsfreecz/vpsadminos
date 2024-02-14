require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  class Operations::Server::CGroup < Operations::Base
    PATH = 'osctl/exportfs/server'.freeze

    # @param server [Server]
    def initialize(server)
      super()
      @server = server
      @cgroup = OsCtl::ExportFS::CGroup.new(PATH)
    end

    def enter_manager
      cgroup.create(manager_path)
      cgroup.enter(manager_path)
    end

    def clear_manager
      cgroup.destroy(manager_path)
    end

    def enter_payload
      cgroup.create(payload_path)
      cgroup.enter(payload_path)
    end

    def clear_payload
      cgroup.kill_all_until_empty(payload_path)
      cgroup.destroy(payload_path)
    end

    def clear_all
      begin
        clear_manager
      rescue Errno::ENOENT
        # ignore
      end

      begin
        clear_payload
      rescue Errno::ENOENT
        # ignore
      end

      nil
    end

    protected

    attr_reader :server, :cgroup

    def path
      server.name
    end

    def manager_path
      File.join(server.name, 'manager')
    end

    def payload_path
      File.join(server.name, 'payload')
    end
  end
end

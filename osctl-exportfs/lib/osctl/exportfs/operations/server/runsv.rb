require 'fileutils'
require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Manage the system runit service on the host
  class Operations::Server::Runsv < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @param name [String]
    def initialize(name)
      @server = Server.new(name)
      @cfg = server.open_config
    end

    # Create the service and place it into runsvdir-managed directory
    def start
      server.synchronize do
        fail 'server is already running' if started?
        fail 'provide server address' if cfg.address.nil?

        FileUtils.mkdir_p(server.runsv_dir)
        run = File.join(server.runsv_dir, 'run')

        ErbTemplate.render_to('runsv', {
          name: server.name,
          address: cfg.address,
          netif: cfg.netif,
        }, run)

        File.chmod(0755, run)
        File.symlink(server.runsv_dir, service_link)
      end
    end

    # Remove the service from the runsvdir-managed directory
    def stop
      server.synchronize do
        File.unlink(service_link) if File.symlink?(service_link)
        sleep(1) until !server.running?
      end
    end

    def restart
      server.synchronize do
        fail 'provide server address' if cfg.address.nil?

        stop
        sleep(1)
        start
      end
    end

    protected
    attr_reader :server, :cfg

    def started?
      File.lstat(service_link)
      true
    rescue Errno::ENOENT
      false
    end

    def service_link
      File.join(RunState::RUNSVDIR, server.name)
    end
  end
end

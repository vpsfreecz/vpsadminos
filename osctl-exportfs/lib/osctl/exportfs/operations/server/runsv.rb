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
    # @param address [String, nil]
    def start(address = nil)
      if started?
        fail 'server already started'
      elsif server.running?
        fail 'server is already running'
      end

      address = address || cfg.address
      fail 'provide server address' if address.nil?

      FileUtils.mkdir_p(server.runsv_dir)
      run = File.join(server.runsv_dir, 'run')

      File.open(run, 'w') do |f|
        f.write(<<END
#!/usr/bin/env bash
exec osctl-exportfs server spawn #{server.name} #{address}
END
)
      end

      File.chmod(0755, run)
      File.symlink(server.runsv_dir, service_link)
    end

    # Remove the service from the runsvdir-managed directory
    def stop
      unless started?
        fail 'server is not running'
      end

      File.unlink(service_link)
    end

    # @param address [String, nil]
    def restart(address = nil)
      address = address || cfg.address
      fail 'provide server address' if address.nil?

      stop
      sleep(1) until !server.running?
      sleep(1)
      start(address)
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

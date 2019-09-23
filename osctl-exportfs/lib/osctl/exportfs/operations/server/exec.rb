require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Attach to the server's namespaces and run an arbitrary code block
  #
  # A new process is forked and attached to namespaces of the server's init
  # process. The code block is run in the forked process.
  class Operations::Server::Exec < Operations::Base
    # @param server [Server]
    def initialize(server, &block)
      @server = server
      @block = block
      @cgroup = Operations::Server::CGroup.new(server)
    end

    def execute
      unless server.running?
        fail 'the server is not running'
      end

      pid = server.read_pid
      namespaces = {
        'mnt' => Sys::CLONE_NEWNS,
        'net' => Sys::CLONE_NEWNET,
        'uts' => Sys::CLONE_NEWUTS,
        'ipc' => Sys::CLONE_NEWIPC,
        'pid' => Sys::CLONE_NEWPID,
      }
      ios = {}

      main = Process.fork do
        cgroup.enter_payload

        namespaces.each do |ns, type|
          ios[ns] = File.open(File.join('/proc', pid.to_s, 'ns', ns), 'r')
        end

        namespaces.each do |ns, type|
          Sys.setns_io(ios[ns], type)
          ios[ns].close
        end

        pid = Process.fork { block.call }
        Process.wait(pid)
      end

      Process.wait(main)
    end

    protected
    attr_reader :server, :block, :cgroup
  end
end

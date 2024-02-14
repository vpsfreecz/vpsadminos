require 'fileutils'
require 'osctl/exportfs/operations/base'

module OsCtl::ExportFS
  # Generate system files for runit
  #
  # Note that this operation has to be called from inside the server's mount
  # namespace.
  class Operations::Runit::Generate < Operations::Base
    # @param server [Server]
    # @param config [Config::TopLevel]
    def initialize(server, config)
      super()
      @server = server
      @vars = {
        server:,
        config:
      }
    end

    def execute
      FileUtils.mkdir_p('/etc/runit')
      %w[1 2 3].each do |v|
        write_script("runit/#{v}", "/etc/runit/#{v}")
      end

      FileUtils.mkdir_p('/etc/runit/runsvdir')
      %w[rpcbind nfsd statd].each do |sv|
        write_service("runsvdir/#{sv}", '/etc/runit/runsvdir', sv)
      end

      return if File.exist?('/service')

      File.symlink('/etc/runit/runsvdir', '/service')
    end

    protected

    attr_reader :server, :vars

    def write_service(template, runsvdir, name)
      svdir = File.join(runsvdir, name)
      FileUtils.mkdir_p(svdir)

      runfile = File.join(svdir, 'run')
      write_script(template, runfile)
    end

    def write_script(template, path)
      ErbTemplate.render_to(template, vars, path)
      File.chmod(0o755, path)
    end
  end
end

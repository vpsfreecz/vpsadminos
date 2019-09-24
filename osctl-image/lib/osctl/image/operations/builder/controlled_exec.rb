require 'libosctl'
require 'osctl/image/operations/base'
require 'securerandom'

module OsCtl::Image
  class Operations::Builder::ControlledExec < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [Builder]
    attr_reader :builder

    # @return [Array<String>]
    attr_reader :command

    # @param builder [Builder]
    # @param command [Array<String>]
    # @param id [nil, String] optional run identifier
    # @param client [nil, OsCtldClient]
    def initialize(builder, command, id: nil, client: nil)
      @builder = builder
      @command = command
      @id = id || SecureRandom.hex(10)
      @client = client || OsCtldClient.new
    end

    # @return [Integer] exit status
    def execute
      begin
        rc = Operations::Builder::RunscriptFromString.run(
          builder,
          start_script,
        )
      ensure
        clear_cgroup
      end

      rc || 1
    end

    protected
    attr_reader :id, :client

    def start_script
      <<EOF
#!/bin/sh
cgroup=/sys/fs/cgroup/systemd/exec.#{id}
mkdir $cgroup
echo $$ >> $cgroup/cgroup.procs
exec #{command.join(' ')}
EOF
    end

    def clear_cgroup
      cgroup = cgroup_path

      unless Dir.exist?(cgroup)
        log(:info, 'cgroup not found, nothing to kill')
        return
      end

      log(:info, "clearing cgroup #{cgroup}")

      if kill_all(cgroup, 'TERM')
        sleep(5)
        kill_all(cgroup, 'KILL')
      end

      Dir.rmdir(cgroup)

    rescue Errno::ENOENT
    end

    def kill_all(cgroup, signal)
      killed = false

      File.open(File.join(cgroup, 'cgroup.procs'), 'r') do |f|
        f.each_line do |line|
          pid = line.strip.to_i

          log(:info, "kill -SIG#{signal} #{pid}")
          Process.kill(signal, pid)
          killed = true
        end
      end

      killed
    end

    def cgroup_path
      File.join(
        '/sys/fs/cgroup/systemd',
        builder.attrs[:group_path],
        'lxc.payload',
        builder.ctid,
        "exec.#{id}"
      )
    end
  end
end

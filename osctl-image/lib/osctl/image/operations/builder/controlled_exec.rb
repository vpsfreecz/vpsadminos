require 'libosctl'
require 'osctl/image/operations/base'

module OsCtl::Image
  class Operations::Builder::ControlledExec < Operations::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System

    # @return [Operations::Builder::Build]
    attr_reader :build

    # @return [Array<String>]
    attr_reader :command

    # @param build [Operations::Builder::Build]
    # @param command [Array<String>]
    # @param client [nil, OsCtldClient]
    def initialize(build, command, client: nil)
      @build = build
      @command = command
      @client = client || OsCtldClient.new
    end

    # @return [Integer] exit status
    def execute
      begin
        rc = Operations::Builder::RunscriptFromString.run(
          build.builder,
          start_script,
        )
      ensure
        clear_cgroup
      end

      rc || 1
    end

    protected
    attr_reader :client

    def start_script
      <<EOF
#!/bin/sh
cgroup=/sys/fs/cgroup/systemd/build.#{build.build_id}
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
        build.builder.attrs[:group_path],
        'lxc',
        build.builder.ctid,
        "build.#{build.build_id}"
      )
    end
  end
end

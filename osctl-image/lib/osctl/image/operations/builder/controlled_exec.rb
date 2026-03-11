require 'libosctl'
require 'osctl/image/operations/base'
require 'securerandom'
require 'shellwords'

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
    # @param env [Hash<String, String>]
    def initialize(builder, command, id: nil, client: nil, env: {})
      super()
      @builder = builder
      @command = command
      @id = id || SecureRandom.hex(10)
      @client = client || OsCtldClient.new
      @env = env
    end

    # @return [Integer] exit status
    def execute
      begin
        rc = Operations::Builder::RunscriptFromString.run(
          builder,
          start_script
        )
      ensure
        clear_cgroup
      end

      rc || 1
    end

    protected

    attr_reader :id, :client, :env

    def start_script
      exec_cmd = ['env']
      exec_cmd.concat(env.map { |k, v| "#{k}=#{v}" }) unless env.empty?
      exec_cmd.concat(command)

      <<~EOF
        #!/bin/sh
        cgroup="#{inner_cgroup_path}"
        mkdir "$cgroup"
        echo $$ >> "$cgroup/cgroup.procs"
        exec #{Shellwords.join(exec_cmd)}
      EOF
    end

    def clear_cgroup
      cgroup = outer_cgroup_path

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
      # ignore
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

    def cgroup_name
      "osctl-image.exec.#{id}"
    end

    def inner_cgroup_path
      if OsCtl::Lib::CGroup.v2?
        File.join('/sys/fs/cgroup', cgroup_name)
      else
        File.join('/sys/fs/cgroup/systemd', cgroup_name)
      end
    end

    def outer_cgroup_path
      if OsCtl::Lib::CGroup.v2?
        File.join(
          '/sys/fs/cgroup',
          builder.attrs[:group_path],
          "lxc.payload.#{builder.ctid}",
          cgroup_name
        )
      else
        File.join(
          '/sys/fs/cgroup/systemd',
          builder.attrs[:group_path],
          "lxc.payload.#{builder.ctid}",
          cgroup_name
        )
      end
    end
  end
end

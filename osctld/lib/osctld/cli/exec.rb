require 'libosctl'
require 'tempfile'

module OsCtld
  class Cli::Exec
    def self.run
      if ARGV.size < 3 || ARGV[1] != '--'
        warn 'Usage: <settings file> -- <command> [arguments...]'
        exit(false)
      end

      OsCtl::Lib::Logger.setup(:none)
      CGroup.init

      cfg = JSON.parse(File.read(ARGV[0]), symbolize_names: true)

      SwitchUser.apply_prlimits(Process.pid, cfg[:prlimits])
      SwitchUser.switch_to(
        cfg[:user],
        cfg[:ugid],
        cfg[:homedir],
        cfg[:cgroup_path],
        syslogns_pid: cfg[:syslogns_pid],
        tracingns_pid: cfg[:tracingns_pid],
        lsmns_pid: cfg[:lsmns_pid]
      )
      exec_command(ARGV[2..], cfg)
    end

    def self.exec_command(cmd, cfg)
      source = cfg[:lxc_attach_config_without_prlimits]

      if source
        exec_lxc_attach_without_prlimits(cmd, source)
      else
        Process.exec(*cmd)
      end
    end

    def self.exec_lxc_attach_without_prlimits(cmd, source)
      config = lxc_attach_config_without_prlimits(source)

      pid = Process.fork do
        Process.exec(*insert_lxc_attach_config(cmd, config.path))
      end

      _, status = Process.wait2(pid)
      exit(exitstatus(status))
    ensure
      if config
        path = config.path
        config.close
        File.unlink(path) if path && File.exist?(path)
      end
    end

    def self.insert_lxc_attach_config(cmd, config_path)
      sep = cmd.index('--') || cmd.length

      cmd[0...sep] + ['-f', config_path] + cmd[sep..]
    end

    def self.lxc_attach_config_without_prlimits(source)
      config = Tempfile.create(['.osctld-lxc-attach', '.conf'])

      File.foreach(source) do |line|
        config.write(line) unless line.start_with?('lxc.prlimit.')
      end

      config.close
      config
    end

    def self.exitstatus(status)
      return status.exitstatus if status.exited?
      return 128 + status.termsig if status.signaled?

      1
    end
  end
end

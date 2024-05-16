require 'libosctl'

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
        syslogns_pid: cfg[:syslogns_pid]
      )
      Process.exec(*ARGV[2..])
    end
  end
end

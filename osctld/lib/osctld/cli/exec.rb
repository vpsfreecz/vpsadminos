module OsCtld
  class Cli::Exec
    def self.run
      sysuser, ugid, homedir, cgroup, *args = ARGV

      SwitchUser.switch_to(sysuser, ugid.to_i, homedir, cgroup)
      Process.exec(*args)
    end
  end
end

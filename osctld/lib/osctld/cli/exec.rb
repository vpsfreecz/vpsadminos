module OsCtld
  class Cli::Exec
    def self.run
      user, sysuser, ugid, homedir, *args = ARGV

      SwitchUser.switch_to(user, sysuser, ugid.to_i, homedir)
      Process.exec(*args)
    end
  end
end

module OsCtld
  module SwitchUser
    def self.switch_to(sysuser, ugid, homedir, cgroup_path, chown_cgroups: true)
      # Environment
      ENV.delete('XDG_SESSION_ID')
      ENV.delete('XDG_RUNTIME_DIR')

      ENV['HOME'] = homedir
      ENV['USER'] = sysuser

      # CGroups
      CGroup.subsystems.each do |subsys|
        CGroup.mkpath(
          subsys,
          cgroup_path.split('/'),
          attach: true,
          chown: chown_cgroups ? ugid : false
        )
      end

      # Switch
      Process.groups = [ugid]
      Process::Sys.setgid(ugid)
      Process::Sys.setuid(ugid)
    end

    def self.switch_to_system(sysuser, uid, gid, homedir)
      # Environment
      ENV.delete('XDG_SESSION_ID')
      ENV.delete('XDG_RUNTIME_DIR')

      ENV['HOME'] = homedir
      ENV['USER'] = sysuser

      # Switch
      Process.groups = [gid]
      Process::Sys.setgid(gid)
      Process::Sys.setuid(uid)
    end
  end
end

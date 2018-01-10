module OsCtld
  module SwitchUser
    def self.switch_to(sysuser, ugid, homedir, cgroup_path)
      # Environment
      ENV.delete('XDG_SESSION_ID')
      ENV.delete('XDG_RUNTIME_DIR')

      ENV['HOME'] = homedir
      ENV['USER'] = sysuser

      # CGroups
      chowned = [
        'freezer', 'cpu,cpuacct', 'net_cls', 'net_cls,net_prio', 'systemd'
      ]

      CGroup.subsystems.each do |subsys|
        CGroup.mkpath(
          subsys,
          cgroup_path.split('/'),
          attach: true,
          chown: chowned.include?(subsys) ? ugid : false
        )
      end

      # Switch
      Process.groups = [ugid]
      Process::Sys.setgid(ugid)
      Process::Sys.setuid(ugid)
    end
  end
end

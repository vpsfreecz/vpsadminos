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

      cgroup_subsystems.each do |subsys|
        cgroup(
          subsys,
          cgroup_path.split('/'),
          attach: true,
          chown: chowned.include?(subsys) ? ugid : false
        )
      end

      # Switch
      Process::Sys.setgid(ugid)
      Process::Sys.setuid(ugid)
    end

    def self.cgroup_subsystems
      Dir.entries(OsCtld::CGROUP_FS) - ['.', '..']
    end

    def self.cgroup(type, path, chown: nil, attach: false)
      base = File.join(OsCtld::CGROUP_FS, type)
      tmp = []

      path.each do |name|
        tmp << name
        cgroup = File.join(base, *tmp)

        next if Dir.exist?(cgroup)

        # Prevent an error if multiple processes attempt to create this cgroup
        # at a time
        begin
          Dir.mkdir(cgroup)

        rescue Errno::EEXIST
          next
        end
      end

      cgroup = File.join(base, *path)
      File.chown(chown, chown, cgroup) if chown

      if attach
        ['tasks', 'cgroup.procs'].each do |tasks|
          tasks_path = File.join(cgroup, tasks)
          next unless File.exist?(tasks_path)

          File.open(tasks_path, 'a') do |f|
            f.write("#{Process.pid}\n")
          end
        end
      end
    end
  end
end

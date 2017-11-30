module OsCtld
  module SwitchUser
    CGROUP_FS = '/sys/fs/cgroup'

    def self.switch_to(user, sysuser, ugid, homedir)
      # Environment
      ENV.delete('XDG_SESSION_ID')
      ENV.delete('XDG_RUNTIME_DIR')

      ENV['HOME'] = homedir
      ENV['USER'] = sysuser

      # CGroups
      cgroup('blkio', ['osctl', user], attach: true)
      cgroup('rdma', ['osctl', user], chown: ugid, attach: true)
      cgroup('freezer', ['osctl', user], chown: ugid, attach: true)
      cgroup('cpuset', ['osctl', user], attach: true)
      cgroup('pids', ['osctl', user], attach: true)
      cgroup('cpu,cpuacct', ['osctl', user], attach: true)
      cgroup('memory', ['osctl', user], attach: true)
      cgroup('net_cls,net_prio', ['osctl', user], attach: true)
      cgroup('devices', ['osctl', user], attach: true)
      cgroup('systemd', ['osctl', user], chown: ugid, attach: true)
      cgroup('unified', ['osctl', user], attach: true)

      # Switch
      Process::Sys.setgid(ugid)
      Process::Sys.setuid(ugid)
    end

    def self.cgroup(type, path, chown: nil, attach: false)
      base = File.join(CGROUP_FS, type)
      tmp = []

      path.each do |name|
        tmp << name
        cgroup = File.join(base, *tmp)

        next if Dir.exist?(cgroup)
        Dir.mkdir(cgroup)
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

require 'libosctl'

module OsCtld
  module SwitchUser
    include OsCtl::Lib::Utils::Log
    extend OsCtl::Lib::Utils::System

    SYSTEM_PATH = %w(/bin /usr/bin /sbin /usr/sbin /run/current-system/sw/bin)

    # Fork a process running as unprivileged user
    # @param sysuser [String]
    # @param ugid [Integer]
    # @param homedir [String]
    # @param cgroup_path [String]
    # @param opts [Hash] options
    # @option opts [Boolean] :chown_cgroups (true)
    # @option opts [Hash] :prlimits
    # @option opts [Integer, nil] :oom_score_adj
    def self.fork_and_switch_to(sysuser, ugid, homedir, cgroup_path, opts = {}, &block)
      r, w = IO.pipe

      pid = Process.fork do
        w.close

        if opts[:oom_score_adj]
          File.open('/proc/self/oom_score_adj', 'w') do |f|
            f.write(opts[:oom_score_adj].to_s)
          end
        end

        switch_to(sysuser, ugid, homedir, cgroup_path, opts)

        msg = r.readline.strip
        r.close

        if msg == 'ready'
          block.call
        else
          exit(false)
        end
      end

      r.close

      apply_prlimits(pid, opts[:prlimits]) if opts[:prlimits]

      w.puts('ready')
      w.close
      pid
    end

    # Switch the current process to an unprivileged user
    def self.switch_to(sysuser, ugid, homedir, cgroup_path, opts = {})
      chown_cgroups = opts.has_key?(:chown_cgroups) ? opts[:chown_cgroups] : true

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

    # Switch the current process to an unprivileged users, but do not change
    # cgroups.
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

    # Apply process resource limits
    # @param pid [Integer]
    # @param prlimits [Hash]
    def self.apply_prlimits(pid, prlimits)
      prlimits.each do |name, limit|
        PrLimits.set(
          pid,
          PrLimits.resource_to_const(name),
          limit[:soft],
          limit[:hard]
        )
      end
    end
  end
end

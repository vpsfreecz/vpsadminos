require 'libosctl'

module OsCtld
  module SwitchUser
    include OsCtl::Lib::Utils::Log
    extend OsCtl::Lib::Utils::System

    SYSTEM_PATH = %w[
      /bin
      /usr/bin
      /sbin
      /usr/sbin
      /run/current-system/sw/bin
      /nix/var/nix/profiles/system/sw/bin
      /run/current-system/profile/bin
      /run/current-system/profile/sbin
      /var/guix/profiles/system/profile/bin
      /var/guix/profiles/system/profile/sbin
    ].freeze

    # Fork into a new process
    #
    # @param opts [Hash]
    # @option opts [Array<IO, Integer>] :keep_fds
    # @option opts [Boolean] :keep_stdfds (true)
    def self.fork(**opts, &block)
      keep_fds = (opts[:keep_fds] || []).clone

      if opts.fetch(:keep_stdfds, true)
        keep_fds << 0 << 1 << 2
      end

      Process.fork do
        close_fds(except: keep_fds)
        block.call
      end
    end

    # Fork a process running as unprivileged user
    # @param sysuser [String]
    # @param ugid [Integer]
    # @param homedir [String]
    # @param cgroup_path [String]
    # @param opts [Hash] options
    # @option opts [Boolean] :chown_cgroups (true)
    # @option opts [Hash] :prlimits
    # @option opts [Integer, nil] :oom_score_adj
    # @option opts [Array<IO, Integer>] :keep_fds
    # @option opts [Boolean] :keep_stdfds (true)
    # @option opts [String, nil] :syslogns_tag (nil)
    # @option opts [Integer, nil] :syslogns_pid (nil)
    def self.fork_and_switch_to(sysuser, ugid, homedir, cgroup_path, **opts, &block)
      chown_cgroups = opts.has_key?(:chown_cgroups) ? opts[:chown_cgroups] : true

      r, w = IO.pipe

      keep_fds = (opts[:keep_fds] || []).clone
      keep_fds << r

      CGroup.mkpath_all(cgroup_path.split('/'), chown: chown_cgroups ? ugid : false)

      pid = self.fork(
        keep_fds:,
        keep_stdfds: opts.fetch(:keep_stdfds, true)
      ) do
        # Closed by self.fork
        # w.close

        if opts[:oom_score_adj]
          File.write('/proc/self/oom_score_adj', opts[:oom_score_adj].to_s)
        end

        switch_to(
          sysuser,
          ugid,
          homedir,
          cgroup_path,
          syslogns_tag: opts.fetch(:syslogns_tag, nil),
          syslogns_pid: opts.fetch(:syslogns_pid, nil)
        )

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
    def self.switch_to(sysuser, ugid, homedir, cgroup_path, syslogns_tag: nil, syslogns_pid: nil)
      if syslogns_tag && syslogns_pid
        raise ArgumentError, 'provide either syslogns_tag or syslogns_pid, not both'
      end

      # Environment
      ENV.delete('XDG_SESSION_ID')

      # LXC places lock files here
      ENV['XDG_RUNTIME_DIR'] = File.join(homedir, '.cache/lxc/run')

      ENV['HOME'] = homedir
      ENV['USER'] = sysuser

      # CGroups
      CGroup.attach_to_all(cgroup_path.split('/'))

      # syslog namespace
      if syslogns_tag
        OsCtl::Lib::Sys.new.create_syslogns(syslogns_tag)
      elsif syslogns_pid
        OsCtl::Lib::Sys.new.attach_syslogns(syslogns_pid)
      end

      # Switch
      Process.groups = [ugid]
      sys = OsCtl::Lib::Sys.new
      sys.setresgid(ugid, ugid, ugid)
      sys.setresuid(ugid, ugid, ugid)
    end

    # Switch the current process to an unprivileged users, but do not change
    # cgroups.
    def self.switch_to_system(sysuser, uid, gid, homedir)
      # Environment
      ENV.delete('XDG_SESSION_ID')

      # LXC places lock files here
      ENV['XDG_RUNTIME_DIR'] = File.join(homedir, '.cache/lxc/run')

      ENV['HOME'] = homedir
      ENV['USER'] = sysuser

      # Switch
      Process.groups = [gid]
      sys = OsCtl::Lib::Sys.new
      sys.setresgid(gid, gid, gid)
      sys.setresuid(uid, uid, uid)
    end

    # Apply process resource limits
    # @param pid [Integer]
    # @param prlimits [Hash]
    def self.apply_prlimits(pid, prlimits)
      prlimits.each do |name, limit|
        PrLimits.set(
          pid,
          PrLimits.resource_to_const(name),
          limit[:soft] == 'unlimited' ? PrLimits::INFINITY : limit[:soft],
          limit[:hard] == 'unlimited' ? PrLimits::INFINITY : limit[:hard]
        )
      end
    end

    # Close open file descriptors
    # @param except [Array<IO, Integer>]
    def self.close_fds(except: [])
      except_filenos = except.map do |v|
        if v.is_a?(::IO)
          v.fileno
        else
          v
        end
      end

      walk_fds do |fd|
        next if except_filenos.include?(fd)

        begin
          IO.new(fd).close
        rescue ArgumentError, Errno::EBADF
          # ignore
        end
      end
    end

    # Yield all open file descriptors
    # @yieldparam [Integer] fd
    def self.walk_fds
      Dir.entries('/proc/self/fd').each do |v|
        next if %w[. ..].include?(v)

        yield(v.to_i)
      end
    end

    # Remove Ruby-related environment variables
    def self.clear_ruby_env
      ENV.delete_if do |k, _v|
        k.start_with?('RUBY') || k.start_with?('BUNDLE') || k.start_with?('GEM')
      end
    end
  end
end

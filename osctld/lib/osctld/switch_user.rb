require 'libosctl'
require 'securerandom'

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
    def self.fork_and_switch_to(sysuser, ugid, homedir, cgroup_path, **opts, &block)
      chown_cgroups = opts.has_key?(:chown_cgroups) ? opts[:chown_cgroups] : true
      pipes = []
      pid = nil
      handed_off = false

      r, w = IO.pipe
      pipes.push(r, w)
      prepared_r, prepared_w = IO.pipe
      pipes.push(prepared_r, prepared_w)

      keep_fds = (opts[:keep_fds] || []).clone
      keep_fds << r << prepared_w

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
          syslogns_tag: opts.fetch(:syslogns_tag, nil)
        )

        # Lowering NOFILE before inherited FDs are closed can prevent even
        # opening /proc/self/fd. Acknowledge preparation before applying limits.
        prepared_w.puts('prepared')
        prepared_w.close

        msg = r.readline.strip
        r.close

        if msg == 'ready'
          block.call
        else
          exit(false)
        end
      end

      r.close
      prepared_w.close

      if prepared_r.readline != "prepared\n"
        raise 'invalid child preparation acknowledgement'
      end

      prepared_r.close

      apply_prlimits(pid, opts[:prlimits]) if opts[:prlimits]

      w.puts('ready')
      w.close
      handed_off = true
      pid
    ensure
      pipes&.each do |pipe|
        pipe.close unless pipe.closed?
      rescue IOError, SystemCallError
        # Close the remaining ends without hiding the original setup failure.
      end

      reap_failed_fork(pid) if pid && !handed_off
    end

    def self.reap_failed_fork(pid)
      # An already-reaped PID is no longer ours to signal. The caller owns
      # successful children; only an incomplete handoff is collected here.
      return if Process.waitpid(pid, Process::WNOHANG)

      begin
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        # The child exited between checking and signalling it.
      end
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
    private_class_method :reap_failed_fork

    # Switch the current process to an unprivileged user
    def self.switch_to(sysuser, ugid, homedir, cgroup_path, syslogns_tag: nil)
      # Environment
      ENV.delete('XDG_SESSION_ID')

      # LXC places lock files here
      ENV['XDG_RUNTIME_DIR'] = File.join(homedir, '.cache/lxc/run')

      ENV['HOME'] = homedir
      ENV['USER'] = sysuser

      # CGroups
      CGroup.attach_to_all(cgroup_path.split('/'))

      sys = OsCtl::Lib::Sys.new

      # syslog namespace
      if syslogns_tag
        create_syslogns(sys, syslogns_tag)
      end

      # Switch
      Process.groups = [ugid]
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

      # A second IO wrapper can close the descriptor without invalidating its
      # original Ruby owner. Later GC could then close a worker's reused fd.
      # Retain and disarm the old owners until their streams are closed below.
      inherited_ios = ObjectSpace.each_object(IO).to_a.filter_map do |io|
        next if io.closed? || except_filenos.include?(io.fileno)

        io.autoclose = false
        if io.stat.pipe?
          begin
            # Detach a duplex pipe's read side while its fd is still valid.
            # Never do this to sockets: shutdown would affect the parent.
            io.close_read
          rescue IOError, Errno::ECHILD
            # Write-only streams, or popen processes owned by the parent.
          end
          next if io.closed? || except_filenos.include?(io.fileno)

          io.autoclose = false
        end
        io
      rescue IOError
        # An allocated but uninitialized IO has no descriptor to discard.
        nil
      rescue Errno::EBADF
        # An already-invalid owner still needs its Ruby stream closed below.
        io
      end

      walk_fds do |fd|
        next if except_filenos.include?(fd)

        begin
          IO.new(fd).close
        rescue ArgumentError, Errno::EBADF
          # ignore
        end
      end

      # Close the Ruby streams only after the raw descriptors are gone, so
      # inherited write buffers cannot be flushed into the parent's pipes.
      inherited_ios.each do |io|
        io.close
      rescue IOError, Errno::EBADF, Errno::ECHILD
        # Buffered flushes see closed fds; popen children belong to the parent.
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

    def self.create_syslogns(sys, tag)
      attempts = 0
      prefix = tag.sub(/-[0-9a-f]{4}\z/, '')
                  .byteslice(0, OsCtl::Lib::Sys::SYSLOGNS_MAX_TAG_BYTESIZE - 5)
                  .sub(/[^A-Za-z0-9]+\z/, '')

      begin
        attempts += 1
        sys.create_syslogns(tag)
      rescue Errno::EEXIST
        raise if attempts >= 8

        # Short run tags can collide with a still-live namespace. Create a
        # fresh one rather than joining it or weakening kernel isolation.
        tag = "#{prefix}-#{SecureRandom.hex(2)}"
        retry
      end
    end
    private_class_method :create_syslogns
  end
end

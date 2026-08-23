require 'base64'
require 'libosctl'
require 'osctld/console/tty'
require 'osctld/process_identity'

module OsCtld
  # Special case for tty0 (/dev/console)
  #
  # tty0 is opened on container start, at least when it's started by osctld.
  # The tty is accessed using unix server socket created by the osctld
  # container wrapper.
  class Console::Console < Console::TTY
    include OsCtl::Lib::Utils::Exception

    CONNECT_RETRY_ERRORS = [Errno::ENOENT, Errno::ECONNREFUSED].freeze
    CONNECT_RETRY_INTERVAL = 0.2

    def initialize(*)
      super
      @connect_mutex = Mutex.new
    end

    def open
      # Does nothing for tty0, it is opened automatically on ct start
    end

    def connect(
      pid,
      socket,
      run_conf,
      effect_id: nil,
      intent_id: nil,
      retry_timeout: nil
    )
      @connect_mutex.synchronize do
        do_connect(
          pid,
          socket,
          run_conf,
          effect_id:,
          intent_id:,
          retry_timeout:
        )
      end
    end

    protected

    def do_connect(
      pid,
      socket,
      run_conf,
      effect_id:,
      intent_id:,
      retry_timeout:
    )
      ensure_connection_current!(run_conf, effect_id:, intent_id:)
      wrapper = ProcessIdentity.capture(pid) if pid
      retry_deadline = monotonic_now + retry_timeout if retry_timeout

      begin
        c = UNIXSocket.new(socket)
      rescue *CONNECT_RETRY_ERRORS => e
        daemon = Daemon.get
        raise if daemon.stopping? || daemon.draining?

        if retry_deadline && monotonic_now >= retry_deadline
          raise e.class,
                "console socket did not become available within #{retry_timeout}s"
        end

        ensure_connection_current!(run_conf, effect_id:, intent_id:)
        if wrapper && !wrapper.alive?
          ct.lifecycle.observe_wrapper_gone(run_conf.run_id)
          raise 'container wrapper exited before the console became available'
        end

        sleep(
          retry_deadline ? [CONNECT_RETRY_INTERVAL, retry_deadline - monotonic_now].min : CONNECT_RETRY_INTERVAL
        )
        retry
      end

      replaced_ios = sync do
        unless connection_current?(run_conf, effect_id:, intent_id:)
          c.close
          raise 'console connection belongs to a superseded lifecycle run'
        end

        old_ios = [tty_in_io, tty_out_io].compact.uniq
        @opened = true
        self.tty_pid = pid
        self.tty_in_io = c
        self.tty_out_io = c
        self.tty_run_conf = run_conf
        wake
        old_ios
      end

      replaced_ios.each do |io|
        io.close
      rescue IOError
        nil
      end
    end

    def ensure_connection_current!(run_conf, effect_id:, intent_id:)
      return if connection_current?(run_conf, effect_id:, intent_id:)

      raise 'console connection belongs to a superseded lifecycle run'
    end

    def connection_current?(run_conf, effect_id:, intent_id:)
      lifecycle = ct.lifecycle
      return false unless lifecycle.active_run_id == run_conf.run_id
      return true unless effect_id

      unless lifecycle.effect_current?(run_conf.run_id, effect_id)
        run = lifecycle.run(run_conf.run_id)
        return false unless run
        return false if run['recovery']
        return false unless run.fetch('pre_start_completed', false)
      end

      intent_id.nil? || lifecycle.current_intent_id == intent_id
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def on_close(run_conf)
      # Console EOF precedes wrapper exit during an ordinary shutdown. The
      # exact wrapper watcher owns the process-liveness transition; treating
      # EOF as wrapper death can start cgroup cleanup while lxc-start still
      # holds the generation.
      nil
    end
  end
end

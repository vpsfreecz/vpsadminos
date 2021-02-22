require 'libosctl'
require 'thread'

module OsCtld
  class Monitor::Master
    include OsCtl::Lib::Utils::Log

    @@instance = nil

    Entry = Struct.new(:thread, :pid, :cts)

    class << self
      def instance
        @@instance = new unless @@instance
        @@instance
      end

      %i(monitor demonitor stop).each do |v|
        define_method(v) do |*args, &block|
          instance.send(v, *args, &block)
        end
      end
    end

    private
    def initialize
      @mutex = Mutex.new
      @monitors = {}
    end

    public
    def monitor(ct)
      sync do
        k = key(ct)

        if @monitors.has_key?(k)
          @monitors[k].cts << ct.id
          update_state(ct)
          next
        end

        t = Thread.new { handle_monitor(ct) }
        @monitors[k] = Entry.new(t, nil, [])
      end

      true
    end

    def demonitor(ct)
      stop_entry = sync do
        k = key(ct)

        entry = @monitors[k]
        entry.cts.delete(ct.id)

        if entry.cts.empty?
          @monitors.delete(k)
          entry
        else
          false
        end
      end

      graceful_stop(stop_entry, ct) if stop_entry
      true
    end

    def stop
      tmp = nil

      sync do
        tmp = @monitors.clone
        @monitors.clear
      end

      tmp.each_value do |entry|
        Process.kill('TERM', entry.pid) if entry.pid
      end

      tmp.each_value do |entry|
        entry.thread.join
      end
    end

    private
    def handle_monitor(ct)
      loop do
        log(
          :info,
          :monitor,
          "Starting user/group monitor for #{ct.user.name}/#{ct.group.name}"
        )

        pid, stdout = Monitor::Process.spawn(ct)
        update_state(ct)

        sync do
          entry = @monitors[key(ct)]
          entry.pid = pid
          entry.cts << ct.id
        end

        p = Monitor::Process.new(ct.pool, ct.user, ct.group, stdout)
        Process.wait(pid) if p.monitor

        log(
          :info,
          :monitor,
          "Monitor of user/group #{ct.user.name}/#{ct.group.name} exited"
        )

        break if sync { !@monitors.has_key?(key(ct)) }
      end
    end

    def update_state(ct)
      st = ContainerControl::Commands::State.run!(ct)
      ct.state = st.state

      if st.init_pid
        ct.ensure_run_conf.init_pid = st.init_pid
      end
    rescue ContainerControl::Error => e
      log(:warn, :monitor, "Unable to get state of container #{ct.ident}: #{e.message}")
    end

    def key(ct)
      "#{ct.user.name}/#{ct.group.name}"
    end

    def sync
      if @mutex.owned?
        yield
      else
        @mutex.synchronize { yield }
      end
    end

    def graceful_stop(entry, ct)
      if entry.pid.nil?
        # PID is nil if the thread is starting
        3.times do
          break if entry.pid
          sleep(1)
        end
      end

      if entry.pid.nil?
        entry.thread.terminate

      else
        Process.kill('TERM', entry.pid)
        entry.thread.join
      end

      Monitor::Process.stop_monitord(ct)
    end
  end
end

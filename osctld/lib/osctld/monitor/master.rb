require 'thread'

module OsCtld
  class Monitor::Master
    include Utils::Log
    include Utils::SwitchUser

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
        key = ct.user.name

        if @monitors.has_key?(key)
          @monitors[key].cts << ct.id
          update_state(ct)
          next
        end

        Thread.new { handle_monitor(ct) }
      end

      true
    end

    def demonitor(ct)
      stop_entry = sync do
        entry = @monitors[ct.user.name]
        entry.cts.delete(ct.id)

        if entry.cts.empty?
          @monitors.delete(ct.user.name)
          entry
        else
          false
        end
      end

      if stop_entry
        Process.kill('TERM', stop_entry.pid)
        stop_entry.thread.join
      end

      true
    end

    def stop
      # When osctld is run in a terminal and interrupted using Ctrl+C, the
      # subprocesses receive SIGINT also, so they may no longer exist, when this
      # code is called.
      sync do
        @monitors.each do |_, entry|
          begin
            Process.kill('TERM', entry.pid)

          rescue Errno::ESRCH
            next
          end
        end
      end
    end

    private
    def handle_monitor(ct)
      loop do
        log(:info, :monitor, "Starting user monitor for #{ct.user.name}")

        pid, stdout = Monitor::Process.spawn(ct.user)
        update_state(ct)
        sync { @monitors[ct.user.name] = Entry.new(Thread.current, pid, [ct.id]) }

        p = Monitor::Process.new(ct.user, stdout)
        Process.wait(pid) if p.monitor

        log(:info, :monitor, "Monitor of user #{ct.user.name} exited")

        break if sync { !@monitors.has_key?(ct.user.name) }

        # The sleep here is essential when osctld is shutting down. If killed
        # from terminal, all processes, including monitors, receive SIGINT
        # on interrupt, so monitors exit and we do not want to restart them.
        # The sleep is here to ensure that osctld has time to call `stop` first.
        sleep(1)
      end
    end

    def update_state(ct)
      ct.inclusively do
        ret = ct_control(ct.user, :ct_status, ids: [ct.id])
        next unless ret[:status]

        out = ret[:output][ct.id.to_sym]
        ct.state = out[:state].to_sym
        ct.init_pid = out[:init_pid]
      end
    end

    def sync
      if @mutex.owned?
        yield
      else
        @mutex.synchronize { yield }
      end
    end
  end
end

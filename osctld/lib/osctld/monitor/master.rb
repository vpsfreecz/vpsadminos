require 'libosctl'
require 'osctld/cgroup'

module OsCtld
  class Monitor::Master
    include OsCtl::Lib::Utils::Log

    @@instance = nil

    Entry = Struct.new(:thread, :pid, :cts)

    class << self
      def instance
        @@instance ||= new
        @@instance
      end

      %i[monitor demonitor stop].each do |v|
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
          next if @monitors[k].cts.include?(ct.id)

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
          "Starting pool/user/group monitor for #{ct.pool.name}:#{ct.user.name}:#{ct.group.name}"
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
          "Monitor of pool/user/group #{ct.pool.name}:#{ct.user.name}:#{ct.group.name} exited"
        )

        break if sync { !@monitors.has_key?(key(ct)) }
      end
    end

    def update_state(ct)
      st = ContainerControl::Commands::State.run!(ct)
      return if ct.state == :error

      run_id = ct.lifecycle.active_run_id
      return unless run_id

      if st.init_pid
        run = ct.lifecycle.run(run_id)
        root = run&.dig('resources', 'cgroup_root')
        unless root && CGroup.get_tree_pids(root).include?(st.init_pid)
          log(
            :warn,
            :monitor,
            "Ignoring unqualified init PID #{st.init_pid} for #{ct.ident} " \
            "run #{run_id}"
          )
          return
        end
      end

      observer_id = Daemon.get.with_lifecycle_admission(
        internal: true,
        continuation: true,
        recovery: true
      ) do
        ct.lifecycle.begin_state_observation(
          run_id,
          st.state,
          init_pid: st.init_pid,
          source: 'state_query'
        )
      end
      return unless observer_id
      return if ct.lifecycle.execution_run?(run_id)
      return unless ct.observe_run_state(run_id, st.state, init_pid: st.init_pid)
      return unless ct.lifecycle.state_observation_current?(run_id, observer_id)

      if st.init_pid
        Eventd.report(
          :ct_init_pid,
          pool: ct.pool.name,
          id: ct.id,
          init_pid: st.init_pid
        )
      end
    rescue CommandFailed
      nil
    rescue ContainerControl::Error => e
      log(:warn, :monitor, "Unable to get state of container #{ct.ident}: #{e.message}")
    ensure
      if run_id && observer_id
        effect_id = ct.lifecycle.finish_state_observation(run_id, observer_id)
        if effect_id
          run_conf = [ct.run_conf, ct.get_past_run_conf].compact.detect do |conf|
            conf.run_id == run_id
          end
          Container::LifecycleFinalizer.spawn(ct, run_conf, effect_id) if run_conf
        end
      end
    end

    def key(ct)
      "#{ct.pool.name}:#{ct.user.name}:#{ct.group.name}"
    end

    def sync(&)
      if @mutex.owned?
        yield
      else
        @mutex.synchronize(&)
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

module OsCtld
  # Used only by oomd command names: old daemons reject the command itself.
  module Commands::Container::OomdGuard
    protected

    def with_oomd_run(ct)
      %i[expected_init_pid expected_init_start_time].each do |key|
        value = opts[key]
        error!("#{key} must be a positive integer") unless value.is_a?(Integer) && value > 0
      end

      # Do not use Commands::Base#manipulate here: its manual 'ignore' option
      # cannot bypass an oomd guard. Existing lifecycle commands re-enter this
      # same-thread lock without releasing it (ManipulationLock#acquire).
      ct.manipulate(self, block: opts[:manipulation_lock] == 'wait') do
        verify_oomd_run!(ct)
        progress("OOMd expected run accepted pid=#{opts[:expected_init_pid]} start=#{opts[:expected_init_start_time]}")
        yield
      end
    end

    def verify_oomd_run!(ct)
      run_conf = ct.run_conf
      error!('oomd expected run is no longer current') unless run_conf && ct.init_pid == opts[:expected_init_pid]

      lease = run_conf.acquire_init_lease
      error!('oomd expected run has no live init') unless lease

      begin
        identity = lease.identity
        fields = identity.read_proc_file('stat').rpartition(') ').last.split
        start_ticks = Integer(fields.fetch(19), 10)
        unless identity.pid == opts[:expected_init_pid] &&
               start_ticks == opts[:expected_init_start_time] && identity.alive? &&
               ct.run_conf.equal?(run_conf) && ct.init_pid == identity.pid
          error!('oomd expected run is no longer current')
        end
      ensure
        # Stop retirement waits for leases. Keep manipulation serialization,
        # but release this short identity lease before entering Stop/Restart.
        lease.close
      end
    rescue SystemCallError, IOError, ArgumentError, IndexError, Container::RunConfiguration::LifecycleError
      error!('oomd expected run identity is unavailable')
    end
  end
end

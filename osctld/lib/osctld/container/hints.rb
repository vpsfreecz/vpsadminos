module OsCtld
  class Container::Hints
    class CpuDaily
      def self.load(cfg)
        new(
          user_us: cfg.fetch('user_us', 0),
          system_us: cfg.fetch('system_us', 0)
        )
      end

      attr_reader :user_us, :system_us, :usage_us

      def initialize(user_us: 0, system_us: 0)
        @user_us = user_us
        @system_us = system_us
        @usage_us = user_us + system_us
      end

      def update(new_user_us, new_system_us, runtime_secs)
        runtime_days = runtime_secs / 60.0 / 60

        cur_user_us = new_user_us / runtime_days

        @user_us = if @user_us > 0
                     ((@user_us + cur_user_us) / 2).round
                   else
                     cur_user_us.round
                   end

        cur_system_us = new_system_us / runtime_days

        @system_us = if @system_us > 0
                       ((@system_us + cur_system_us) / 2).round
                     else
                       cur_system_us.round
                     end

        @usage_us = @user_us + @system_us
      end

      def dump
        {
          'user_us' => user_us,
          'system_us' => system_us
        }
      end
    end

    # @param ct [Container]
    # @param cfg [Hash]
    def self.load(ct, cfg)
      new(
        ct,
        cpu_daily: CpuDaily.load(cfg.fetch('cpu_daily', {}))
      )
    end

    include Lockable

    # @return [Container]
    attr_reader :ct

    # @return [CpuDaily]
    attr_reader :cpu_daily

    # @param ct [Container]
    def initialize(ct, cpu_daily: nil)
      init_lock
      @ct = ct
      @cpu_daily = cpu_daily || CpuDaily.new(user_us: 0, system_us: 0)
    end

    def account_cpu_use
      cg_reader = OsCtl::Lib::CGroup::PathReader.new(
        CGroup.subsystem_paths,
        ct.base_cgroup_path
      )

      vals = cg_reader.read_stats(%i[cpu_us cpu_user_us cpu_system_us], true)
      return if !vals[:cpu_us] || !vals[:cpu_user_us] || !vals[:cpu_system_us]

      begin
        st = File.stat(CGroup.abs_cgroup_path('cpuacct', ct.base_cgroup_path))
      rescue SystemCallError
        return
      end

      elapsed_time = Time.now - st.mtime

      exclusively do
        cpu_daily.update(vals[:cpu_user_us].raw, vals[:cpu_system_us].raw, elapsed_time)
      end
    end

    def dump
      {
        'cpu_daily' => cpu_daily.dump
      }
    end

    def dup(new_ct)
      ret = super()
      ret.init_lock
      ret.instance_variable_set('@ct', new_ct)
      ret.instance_variable_set('@cpu_daily', cpu_daily.dup)
      ret
    end
  end
end

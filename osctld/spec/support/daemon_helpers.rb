# frozen_string_literal: true

module DaemonHelpers
  SchedulerPackageConfig = Struct.new(:cpu_mask, :enable, keyword_init: true)
  RestartConfig = Struct.new(:hook_timeout, keyword_init: true)

  SchedulerConfig = Struct.new(
    :enable_flag,
    :min_package_container_count_percent,
    :packages,
    :sequential_start_priority_threshold,
    keyword_init: true
  ) do
    def enable?
      enable_flag
    end
  end

  def stub_daemon(debug: false, cpu_scheduler: nil)
    scheduler_cfg = cpu_scheduler || SchedulerConfig.new(
      enable_flag: true,
      min_package_container_count_percent: 75,
      packages: {},
      sequential_start_priority_threshold: 1000
    )

    daemon_config = Struct.new(:debug?, :cpu_scheduler, :restart).new(
      debug,
      scheduler_cfg,
      RestartConfig.new(hook_timeout: 30)
    )
    daemon = Struct.new(:config) do
      def with_lifecycle_admission(**)
        yield
      end

      def with_lifecycle_admission_context(**)
        yield
      end

      def with_lifecycle_task(**)
        yield
      end

      def ready?
        true
      end

      def stopping?
        false
      end

      def draining?
        false
      end

      def upgrade_handoff_desired?(_ct)
        false
      end

      def fulfil_upgrade_handoff(_ct); end

      def lifecycle_state_changed; end
    end.new(daemon_config)

    stub_const('OsCtld::Daemon', Class.new do
      def self.get
        nil
      end
    end)
    allow(OsCtld::Daemon).to receive(:get).and_return(daemon)
  end
end

RSpec.configure do |config|
  config.include DaemonHelpers
end

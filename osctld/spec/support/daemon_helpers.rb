# frozen_string_literal: true

module DaemonHelpers
  SchedulerPackageConfig = Struct.new(:cpu_mask, :enable, keyword_init: true)

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

    daemon_config = Struct.new(:debug?, :cpu_scheduler).new(debug, scheduler_cfg)
    daemon = Struct.new(:config).new(daemon_config)

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

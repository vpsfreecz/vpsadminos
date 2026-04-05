# frozen_string_literal: true

module FakeOsctldClientHelpers
  def build_connected_osctld_client(**overrides)
    defaults = {
      connected?: true,
      ping?: true,
      status: {},
      list_pools: [],
      list_containers: [],
      list_netifs: [],
      cpu_scheduler_status: {},
      list_cpu_packages: [],
      health_check: [],
      client: instance_double(OsCtl::Client)
    }

    instance_double(OsCtl::Exporter::OsCtldClient, **defaults, **overrides)
  end

  def build_disconnected_osctld_client(**overrides)
    build_connected_osctld_client(connected?: false, ping?: false, **overrides)
  end
end

RSpec.configure do |config|
  config.include FakeOsctldClientHelpers
end

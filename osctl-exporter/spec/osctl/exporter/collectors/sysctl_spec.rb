# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::Sysctl do
  it 'reads the configured procfs sysctl paths' do
    registry = OsCtl::Exporter::Registry.new
    collector = described_class.new(instance_double(OsCtl::Exporter::Collector), registry)

    allow(File).to receive(:read).with('/proc/sys/kernel/keys/maxkeys').and_return("1\n")
    allow(File).to receive(:read).with('/proc/sys/kernel/keys/maxbytes').and_return("2\n")
    allow(File).to receive(:read).with('/proc/sys/kernel/pty/max').and_return("3\n")
    allow(File).to receive(:read).with('/proc/sys/kernel/pty/reserve').and_return("4\n")
    allow(File).to receive(:read).with('/proc/sys/kernel/pty/nr').and_return("5\n")

    collector.run_collect(build_disconnected_osctld_client)

    expect(metric_values(registry.get(:sysctl_kernel_keys_maxkeys))).to eq({ {} => 1.0 })
    expect(metric_values(registry.get(:sysctl_kernel_keys_maxbytes))).to eq({ {} => 2.0 })
    expect(metric_values(registry.get(:sysctl_kernel_pty_max))).to eq({ {} => 3.0 })
    expect(metric_values(registry.get(:sysctl_kernel_pty_reserve))).to eq({ {} => 4.0 })
    expect(metric_values(registry.get(:sysctl_kernel_pty_nr))).to eq({ {} => 5.0 })
  end
end

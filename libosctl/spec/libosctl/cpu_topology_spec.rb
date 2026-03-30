# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/cpu_topology'

RSpec.describe OsCtl::Lib::CpuTopology do
  def with_fake_cpu_sysfs
    with_tmpdir do |dir|
      sys_dir = File.join(dir, 'sys/devices/system/cpu')

      write_sysfs_file(sys_dir, 'cpu0/topology/physical_package_id', "0\n")
      write_sysfs_file(sys_dir, 'cpu1/online', "0\n")
      write_sysfs_file(sys_dir, 'cpu1/topology/physical_package_id', "0\n")
      write_sysfs_file(sys_dir, 'cpu2/online', "1\n")
      write_sysfs_file(sys_dir, 'cpu2/topology/physical_package_id', "1\n")
      write_sysfs_file(sys_dir, 'cpu3/online', "1\n")
      write_sysfs_file(sys_dir, 'cpu3/topology/physical_package_id', "1\n")

      allow(Dir).to receive(:glob).with('/sys/devices/system/cpu/cpu*').and_return(
        Dir.glob(File.join(sys_dir, 'cpu*'))
      )

      allow(File).to receive(:read).and_wrap_original do |method, path, *args|
        if path.start_with?('/sys/devices/system/cpu')
          method.call(path.sub('/sys/devices/system/cpu', sys_dir), *args)
        else
          method.call(path, *args)
        end
      end

      yield
    end
  end

  it 'builds packages, skips offline CPUs, and treats missing online files as online' do
    topology = nil

    with_fake_cpu_sysfs do
      topology = described_class.new
    end

    expect(topology.packages.keys).to eq([0, 1])
    expect(topology.cpus.keys).to eq([0, 2, 3])
    expect(topology.packages[0].cpus.keys).to eq([0])
    expect(topology.packages[1].cpus.keys).to eq([2, 3])
    expect(topology.cpus[0].package_id).to eq(0)
    expect(topology.cpus[2].package_id).to eq(1)
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Host do
  it 'computes cpu diffs and totals' do
    cpu1 = described_class::Cpu.new(10, 0, 5, 20, 0, 0, 0, 0, 0, 0)
    sleep 0.001
    cpu2 = described_class::Cpu.new(20, 0, 15, 30, 0, 0, 0, 0, 0, 0)
    diff = cpu2.diff(cpu1)

    expect(diff.total).to be > 0
    expect(diff.total_used).to be > 0
  end

  it 'overrides memory and process counts in host results' do
    host = described_class.new(nil)
    m1 = instance_double(OsCtl::Cli::Top::Measurement)
    m2 = instance_double(OsCtl::Cli::Top::Measurement)
    allow(m2).to receive(:diff_from).with(m1, :realtime).and_return(memory: 1, nproc: 2)
    host.instance_variable_set(:@measurements, [m1, m2])
    host.instance_variable_set(:@initial, m1)

    result = host.result(:realtime, double(used: 4), double(total: 7))

    expect(result[:memory]).to eq(4096)
    expect(result[:nproc]).to eq(7)
  end

  it 'shapes zfs results with and without iostat data' do
    host = described_class.new(nil)
    current_arc = double(
      c_max: 10,
      c: 8,
      size: 7,
      hit_rate: 80.0,
      misses: 2,
      l2_size: 6,
      l2_asize: 5,
      l2_hit_rate: 90.0,
      l2_misses: 1
    )
    previous_arc = double('previous_arc')
    iostat = double(io_read: 1, io_written: 2, bytes_read: 3, bytes_written: 4)
    host.instance_variable_set(:@zfs, [{ arcstats: previous_arc, iostat: nil }, { arcstats: current_arc, iostat: iostat }])

    expect(host.zfs_result).to eq(
      arcstats: {
        arc: { c_max: 10, c: 8, size: 7, hit_rate: 80.0, misses: 2 },
        l2arc: { size: 6, asize: 5, hit_rate: 90.0, misses: 1 }
      },
      iostat: { io_read: 1, io_written: 2, bytes_read: 3, bytes_written: 4 }
    )
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'timeout'
require 'libosctl/zfs/iostat'

RSpec.describe OsCtl::Lib::Zfs::IOStat do
  it 'aggregates pool stats with PoolStats#<<' do
    left = described_class::PoolStats.new('tank', 1, 2, 3, 4, 5, 6)
    right = described_class::PoolStats.new('fast', 7, 8, 9, 10, 11, 12)

    left << right

    expect(left.alloc).to be_nil
    expect(left.free).to be_nil
    expect(left.io_read).to eq(12)
    expect(left.io_written).to eq(14)
    expect(left.bytes_read).to eq(16)
    expect(left.bytes_written).to eq(18)
  end

  it 'parses current and accumulated pool stats and aggregates current_all' do
    reader = described_class.new
    reader.send(:parser, StringIO.new("tank\t1\t2\t3\t4\t5\t6\nfast\t7\t8\t9\t10\t11\t12\n"))

    expect(reader.current_pool('tank')).to have_attributes(alloc: 1, free: 2, io_read: 3, io_written: 4)
    expect(reader.current_pool('fast')).to have_attributes(bytes_read: 11, bytes_written: 12)
    expect(reader.current_all).to have_attributes(io_read: 12, io_written: 14, bytes_read: 16, bytes_written: 18)
    expect(reader.accumulated_all).to have_attributes(io_read: 12, io_written: 14, bytes_read: 16, bytes_written: 18)

    reader.send(:parser, StringIO.new("tank\t1\t2\t1\t1\t1\t1\n"))

    expect(reader.accumulated_pool('tank')).to have_attributes(io_read: 4, io_written: 5, bytes_read: 6, bytes_written: 7)
  end

  it 'closes both pipe ends and joins the reader if spawning zpool fails' do
    r, w = IO.pipe
    allow(IO).to receive(:pipe).and_return([r, w])
    error = Errno::ENOENT.new('zpool')
    allow(Process).to receive(:spawn).with('zpool', 'iostat', '-Hpy', '1', out: w).and_raise(error)
    iostat = described_class.new
    reader = nil
    allow(Thread).to receive(:new).and_wrap_original do |start, &block|
      reader = start.call(&block)
    end

    Timeout.timeout(2) do
      expect { iostat.start }.to raise_error(Errno::ENOENT) { |raised| expect(raised).to equal(error) }
      expect(r).to be_closed
      expect(w).to be_closed
      expect(reader).not_to be_alive
      2.times { iostat.stop }
      expect(iostat).not_to be_started
    end
  ensure
    w&.close unless w&.closed?
    reader&.join(2)
    r&.close unless r&.closed?
  end

  it 'restarts when pools change and drops removed pool stats' do
    reader = described_class.new(pools: ['tank'])
    allow(reader).to receive(:start)
    allow(reader).to receive(:stop)
    allow(reader).to receive(:started?).and_return(true)

    reader.add_pool('fast')
    expect(reader.pools).to eq(%w[tank fast])

    reader.instance_variable_get(:@current_stats)['fast'] = described_class::PoolStats.new('fast', 1, 1, 1, 1, 1, 1)
    reader.instance_variable_get(:@accumulated_stats)['fast'] = described_class::PoolStats.new('fast', 1, 1, 1, 1, 1, 1)
    reader.remove_pool('fast')

    expect(reader.pools).to eq(['tank'])
    expect(reader.current_pool('fast')).to be_nil
    expect(reader.accumulated_pool('fast')).to be_nil

    reader.instance_variable_get(:@current_stats)['tank'] = described_class::PoolStats.new('tank', 1, 1, 1, 1, 1, 1)
    reader.instance_variable_get(:@accumulated_stats)['tank'] = described_class::PoolStats.new('tank', 1, 1, 1, 1, 1, 1)
    reader.pools = ['fast']

    expect(reader.pools).to eq(['fast'])
    expect(reader.current_pool('tank')).to be_nil
    expect(reader.accumulated_pool('tank')).to be_nil
  end
end

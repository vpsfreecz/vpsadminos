# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/uptime'
require 'libosctl/zfs/zpool_transaction_groups'

RSpec.describe OsCtl::Lib::Zfs::ZpoolTransactionGroups do
  it 'reads transaction groups from proc files and computes birth times' do
    with_tmpdir do |dir|
      stub_const("#{described_class}::PROC_PATH", dir)
      FileUtils.mkdir_p(File.join(dir, 'tank'))
      FileUtils.mkdir_p(File.join(dir, 'fast'))

      File.write(File.join(dir, 'tank', 'txgs'), <<~TXGS)
        txg birth state ndirty nread nwritten reads writes otime qtime wtime stime
        1 1000000000 C 1 2 3 4 5 6 7 8 9
        2 2000000000 O 1 2 3 4 5 6 7 8 9
      TXGS

      File.write(File.join(dir, 'fast', 'txgs'), <<~TXGS)
        txg birth state ndirty nread nwritten reads writes otime qtime wtime stime
        1 3000000000 C 1 2 3 4 5 6 7 8 9
      TXGS

      allow(OsCtl::Lib::Uptime).to receive(:new).and_return(instance_double(OsCtl::Lib::Uptime, booted_at: Time.at(100)))

      txgs = described_class.new

      expect(txgs.pools.keys.sort).to eq(%w[fast tank])
      expect(txgs.pools['tank'].last.txg).to eq(2)
      expect(txgs.pools['tank'].last_committed.txg).to eq(1)
      expect(txgs.pools['tank'].opened.txg).to eq(2)
      expect(txgs.pools['tank'].last.birth_time).to eq(Time.at(102))
      expect(txgs.pools['tank'].last).to be_open
      expect(txgs.pools['tank'].last_committed).to be_committed
    end
  end

  it 'lists transaction groups since an older snapshot and tracks changed states' do
    old_list = described_class::TransactionGroupList.new
    new_list = described_class::TransactionGroupList.new

    old_list << described_class::TransactionGroup.new(pool: 'tank', txg: 1, state: :committed)
    old_list << described_class::TransactionGroup.new(pool: 'tank', txg: 2, state: :open)

    new_list << described_class::TransactionGroup.new(pool: 'tank', txg: 1, state: :committed)
    new_list << described_class::TransactionGroup.new(pool: 'tank', txg: 2, state: :committed)
    new_list << described_class::TransactionGroup.new(pool: 'tank', txg: 3, state: :open)

    expect(new_list.since(old_list).each.map(&:txg)).to eq([3])
    expect(new_list.since(old_list, changed: true).each.map(&:txg)).to eq([2, 3])
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'libosctl/zfs/stream'

RSpec.describe OsCtl::Lib::Zfs::Stream do
  it 'builds full and incremental zfs send commands with option flags' do
    full = described_class.new('tank/ct/test', 'b')
    incremental = described_class.new(
      'tank/ct/test',
      'b',
      'a',
      intermediary: false,
      compressed: true,
      properties: false,
      large_block: false
    )

    expect(full.send(:full_zfs_send_cmd)).to eq('zfs send -p -L -v tank/ct/test@b')
    expect(incremental.send(:full_zfs_send_cmd)).to eq('zfs send -c -v -i @a tank/ct/test@b')
  end

  it 'parses sizes, total size output, and transfered amounts' do
    stream = described_class.new('tank/ct/test', 'b')

    expect(stream.send(:parse_size, '10')).to eq(0)
    expect(stream.send(:parse_size, '2M')).to eq(2)
    expect(stream.send(:parse_total_size, StringIO.new("noise\ntotal estimated size is 5M\n"))).to eq(5)
    expect(stream.send(:parse_transfered, "00:00:01 1M tank/ct/test@a\n")).to eq(1)
    expect(stream.send(:parse_transfered, "TIME SENT SNAPSHOT\n")).to be_nil
  end

  it 'estimates size from zfs send -n -v output' do
    stream = described_class.new('tank/ct/test', 'b', 'a', compressed: true)

    allow(stream).to receive(:zfs).with(
      :send,
      '-nvc -I @a',
      'tank/ct/test@b'
    ).and_return(command_result(output: "total estimated size is 12M\n"))

    expect(stream.size).to eq(12)
    expect(stream).to have_received(:zfs).with(
      :send,
      '-nvc -I @a',
      'tank/ct/test@b'
    )
  end

  it 'tracks progress across snapshot boundaries' do
    stream = described_class.new('tank/ct/test', 'b')
    observed = []

    stream.progress do |total, transfered, sent|
      observed << [total, transfered, sent]
    end

    stream.send(
      :monitor_progress,
      StringIO.new(
        "TIME SENT SNAPSHOT\n" \
        "00:00:01 1M tank@a\n" \
        "00:00:02 2M tank@a\n" \
        "TIME SENT SNAPSHOT\n" \
        "00:00:03 1M tank@b\n"
      )
    )

    expect(observed).to eq(
      [
        [1, 1, 1],
        [2, 2, 1],
        [3, 1, 1]
      ]
    )
  end
end

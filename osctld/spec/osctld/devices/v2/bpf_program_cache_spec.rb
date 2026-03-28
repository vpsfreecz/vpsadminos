# frozen_string_literal: true

require 'osctld/devices/device'
require 'osctld/devices/mode'
require 'osctld/bpf_fs'
require 'osctld/devices/v2/bpf_program_cache'

RSpec.describe OsCtld::Devices::V2::BpfProgramCache do
  let(:cache) { described_class.send(:new) }
  let(:dev_a) { OsCtld::Devices::Device.new(:char, 1, 3, 'rwm') }
  let(:dev_b) { OsCtld::Devices::Device.new(:block, 8, 0, 'rw') }

  before do
    OsCtl::Lib::Logger.setup(:none)
    allow(OsCtld::BpfFs).to receive(:list_progs).and_return([])
  end

  it 'hashes devices independently of ordering' do
    expect(cache.get_prog_name([dev_a, dev_b])).to eq(cache.get_prog_name([dev_b, dev_a]))
  end
end

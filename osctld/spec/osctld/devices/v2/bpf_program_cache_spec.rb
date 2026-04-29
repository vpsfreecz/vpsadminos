# frozen_string_literal: true

require 'osctld/devices/device'
require 'osctld/devices/mode'
require 'osctld/bpf_fs'
require 'osctld/devices/v2/bpf_link'
require 'osctld/devices/v2/bpf_program'
require 'osctld/devices/v2/bpf_program_cache'

RSpec.describe OsCtld::Devices::V2::BpfProgramCache do
  let(:cache) { described_class.send(:new) }
  let(:dev_a) { OsCtld::Devices::Device.new(:char, 1, 3, 'rwm') }
  let(:dev_b) { OsCtld::Devices::Device.new(:block, 8, 0, 'rw') }

  before do
    OsCtl::Lib::Logger.setup(:none)
    allow(OsCtld::BpfFs).to receive(:list_progs).and_return([])
  end

  it 'hashes devices according to ordering' do
    expect(cache.get_prog_name([dev_a, dev_b])).not_to eq(
      cache.get_prog_name([dev_b, dev_a])
    )
  end

  it 'recreates missing pin directories before attaching programs' do
    prog = instance_double(
      OsCtld::Devices::V2::BpfProgram,
      exist?: false,
      create: nil,
      attached?: false,
      attach: nil
    )

    allow(OsCtld::Devices::V2::BpfProgram).to receive(:new).and_return(prog)
    allow(OsCtld::BpfFs).to receive(:link_pinned?).and_return(false)

    expect(OsCtld::BpfFs).to receive(:setup).ordered
    expect(OsCtld::BpfFs).to receive(:add_pool).with('tank').ordered

    cache.set('tank', [dev_a], '/sys/fs/cgroup/osctl/pool.tank/ct.testct')
  end
end

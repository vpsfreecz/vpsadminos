# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Ps::Columns do
  let(:process) do
    double(
      'process',
      ct_id: %w[tank ct1],
      pid: 100,
      ct_pid: 10,
      ruid: 1000,
      rgid: 1000,
      euid: 1000,
      egid: 1000,
      vmsize: 2048,
      rss: 1024,
      state: 'S',
      start_time: Time.now,
      user_time: 2,
      sys_time: 3,
      cmdline: '',
      name: 'ruby',
      ct_ruid: 0,
      ct_rgid: 0,
      ct_euid: 0,
      ct_egid: 0
    )
  end

  it 'uses the process name when the command line is empty' do
    row = described_class.new(process, false)

    expect(row.command).to eq('[ruby]')
  end

  it 'falls back to negative host ids when id mapping fails' do
    allow(process).to receive(:ct_euid).and_raise(OsCtl::Lib::Exceptions::IdMappingError.new('idmap', 1000))

    row = described_class.new(process, false)

    expect(row.cteuid).to eq(-1000)
  end

  it 'generates column specs and skips vanished processes' do
    missing = double('process')
    allow(missing).to receive(:ct_id).and_raise(OsCtl::Lib::Exceptions::OsProcessNotFound.new(1))

    spec, data = described_class.generate([process, missing], %i[pool ctid command], false)

    expect(spec.map { |col| col[:name] }).to eq(%i[pool ctid command])
    expect(data).to eq([{ pool: 'tank', ctid: 'ct1', command: '[ruby]' }])
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Config::Nfsd do
  it 'uses the expected defaults' do
    cfg = described_class.new({})

    expect(cfg.nproc).to eq(8)
    expect(cfg.tcp).to be(true)
    expect(cfg.udp).to be(false)
    expect(cfg.versions).to eq(%w[3 4 4.0 4.1 4.2])
    expect(cfg.syslog).to be(false)
    expect(cfg.allowed_versions).to eq(%w[3 4 4.0 4.1 4.2])
    expect(cfg.disallowed_versions).to eq([])
  end

  it 'loads custom values and dumps them' do
    cfg = described_class.new(
      'port' => 2049,
      'nproc' => 16,
      'tcp' => false,
      'udp' => true,
      'versions' => %w[4.1 4.2],
      'syslog' => true
    )

    expect(cfg.port).to eq(2049)
    expect(cfg.allowed_versions).to eq(%w[4.1 4.2])
    expect(cfg.disallowed_versions).to eq(%w[3 4 4.0])
    expect(cfg.dump).to eq(
      'port' => 2049,
      'nproc' => 16,
      'tcp' => false,
      'udp' => true,
      'versions' => %w[4.1 4.2],
      'syslog' => true
    )
  end
end

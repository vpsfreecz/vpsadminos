# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::ContainerConfig do
  subject(:config) do
    described_class.new.tap do |cfg|
      cfg.distribution = 'alpine'
      cfg.version = '3.20'
      cfg.arch = 'x86_64'
      cfg.vendor = 'vendor'
      cfg.variant = 'minimal'
      cfg.dataset = dataset
    end
  end

  let(:dataset) do
    instance_double(
      OsCtl::Lib::Zfs::Dataset,
      descendants: [
        instance_double(OsCtl::Lib::Zfs::Dataset),
        instance_double(OsCtl::Lib::Zfs::Dataset)
      ]
    )
  end

  it 'returns the root dataset followed by descendants' do
    expect(config.datasets).to eq([dataset] + dataset.descendants)
  end

  it 'dumps the image metadata to a config hash' do
    expect(config.dump_config).to eq(
      'distribution' => 'alpine',
      'version' => '3.20',
      'arch' => 'x86_64',
      'vendor' => 'vendor',
      'variant' => 'minimal'
    )
  end

  it 'merges overrides into the dumped config' do
    config.override_with('hostname' => 'test-vm')

    expect(config.dump_config).to include('hostname' => 'test-vm')
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Image do
  describe 'name parsing' do
    it 'parses a full image name into attributes' do
      image = described_class.new('/build-scripts', 'alpine-3.20-aarch64-vendor-full')

      expect(image.distribution).to eq('alpine')
      expect(image.version).to eq('3.20')
      expect(image.arch).to eq('aarch64')
      expect(image.vendor).to eq('vendor')
      expect(image.variant).to eq('full')
    end

    it 'defaults arch, vendor and variant for a short name' do
      image = described_class.new('/build-scripts', 'alpine')

      expect(image.distribution).to eq('alpine')
      expect(image.arch).to eq('x86_64')
      expect(image.vendor).to eq('vpsadminos')
      expect(image.variant).to eq('minimal')
    end
  end

  describe '#load_config' do
    subject(:image) { described_class.new('/build-scripts', 'alpine') }

    it 'requires the builder attribute' do
      allow(OsCtl::Image::Operations::Config::ParseAttrs).to receive(:run).and_return({})

      expect { image.load_config }.to raise_error(RuntimeError, 'builder not set for alpine')
    end

    it 'loads attributes and dataset mappings from the config output' do
      allow(OsCtl::Image::Operations::Config::ParseAttrs).to receive(:run).and_return(
        'BUILDER' => 'default',
        'DISTNAME' => 'Alpine',
        'RELVER' => '3.20',
        'ARCH' => 'aarch64',
        'VENDOR' => 'vendor',
        'VARIANT' => 'full',
        'DATASETS' => 'var=/var:log=/var/log'
      )

      image.load_config

      expect(image.builder).to eq('default')
      expect(image.distribution).to eq('Alpine')
      expect(image.version).to eq('3.20')
      expect(image.arch).to eq('aarch64')
      expect(image.vendor).to eq('vendor')
      expect(image.variant).to eq('full')
      expect(image.datasets).to eq('var' => '/var', 'log' => '/var/log')
    end
  end

  it 'returns its name from #to_s' do
    image = described_class.new('/build-scripts', 'alpine')

    expect(image.to_s).to eq('alpine')
  end
end

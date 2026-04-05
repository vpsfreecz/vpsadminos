# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Export do
  describe '.load' do
    it 'loads persisted string-keyed hashes' do
      export = described_class.load(
        'dir' => '/srv/data',
        'as' => '/exports/data',
        'host' => '10.0.0.0/24',
        'options' => 'ro'
      )

      expect(export).to have_attributes(
        dir: '/srv/data',
        as: '/exports/data',
        host: '10.0.0.0/24',
        options: 'ro'
      )
    end
  end

  it 'defaults export target to the source directory' do
    export = described_class.new(dir: '/srv/data', host: '*', options: 'rw')

    expect(export.as).to eq('/srv/data')
  end

  it 'supports an explicit export target and dump round-trip' do
    export = described_class.new(
      dir: '/srv/data',
      as: '/exports/data',
      host: '*',
      options: 'rw'
    )

    expect(described_class.load(export.dump)).to have_attributes(
      dir: '/srv/data',
      as: '/exports/data',
      host: '*',
      options: 'rw'
    )
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Config::Exports do
  let(:primary_export) do
    OsCtl::ExportFS::Export.new(
      dir: '/srv/data',
      as: '/exports/data',
      host: '*',
      options: 'rw'
    )
  end
  let(:secondary_export) do
    OsCtl::ExportFS::Export.new(
      dir: '/srv/data',
      as: '/exports/data',
      host: '10.0.0.0/24',
      options: 'ro'
    )
  end

  it 'initializes from persisted config and supports lookup/mutation' do
    cfg = described_class.new([primary_export.dump])

    expect(cfg.lookup('/exports/data', '*')).to have_attributes(
      dir: primary_export.dir,
      as: primary_export.as,
      host: primary_export.host,
      options: primary_export.options
    )

    cfg << secondary_export
    expect(cfg.lookup('/exports/data', '10.0.0.0/24')).to eq(secondary_export)

    cfg.remove(cfg.lookup('/exports/data', '*'))
    expect(cfg.lookup('/exports/data', '*')).to be_nil
    expect(cfg.dump).to eq([secondary_export.dump])
  end

  it 'normalizes paths in find_by_as' do
    cfg = described_class.new([primary_export.dump])

    with_tmpdir do |tmpdir|
      Dir.chdir(tmpdir) do
        expect(cfg.find_by_as('/exports/data')).to have_attributes(
          as: primary_export.as,
          dir: primary_export.dir
        )
        expect(cfg.find_by_as('/exports/../exports/data')).to have_attributes(
          as: primary_export.as,
          dir: primary_export.dir
        )
      end
    end
  end

  it 'groups exports by target and rejects conflicting sources' do
    cfg = described_class.new([primary_export.dump, secondary_export.dump])

    grouped = cfg.group_by_as
    expect(grouped.size).to eq(1)
    expect(grouped.first[0]).to eq('/srv/data')
    expect(grouped.first[1]).to eq('/exports/data')
    expect(grouped.first[2].map(&:host)).to eq(['*', '10.0.0.0/24'])

    conflict = OsCtl::ExportFS::Export.new(
      dir: '/srv/other',
      as: '/exports/data',
      host: '192.0.2.0/24',
      options: 'rw'
    )
    cfg << conflict

    expect { cfg.group_by_as }.to raise_error(
      RuntimeError,
      'target export path /exports/data has two source paths: /srv/other and /srv/data'
    )
  end
end

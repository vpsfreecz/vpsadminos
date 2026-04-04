# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::ZfsProperties do
  subject(:helper) { described_class.new }

  let(:reader) { instance_double(OsCtl::Lib::Zfs::PropertyReader) }
  let(:tree) { double('tree') }

  before do
    allow(OsCtl::Lib::Zfs::PropertyReader).to receive(:new).and_return(reader)
  end

  it 'normalizes symbol property names and zfs abbreviations' do
    expect(
      helper.validate_property_names(%i[id zfs.avail zfs.compress])
    ).to eq(%i[id zfs.available zfs.compression])
  end

  it 'returns non-zfs columns unchanged' do
    expect(helper.validate_property_names(%i[id pool])).to eq(%i[id pool])
  end

  it 'does nothing when no zfs properties are selected' do
    data = { dataset: 'tank/ct1' }

    expect(reader).not_to receive(:read)

    helper.add_container_values(data, %i[id pool])
    expect(data).to eq(dataset: 'tank/ct1')
  end

  it 'adds property values to a single hash target' do
    dataset = double('dataset', name: 'tank/ct1', properties: { 'creation' => '1000', 'used' => '2048' })
    allow(reader).to receive(:read).with(['tank/ct1'], %w[creation used]).and_return(tree)
    allow(tree).to receive(:each_tree_dataset).and_yield(dataset)
    data = { dataset: 'tank/ct1' }

    helper.add_container_values(data, %i[zfs.creation zfs.used])

    expect(data[:'zfs.creation']).to be_a(OsCtl::Lib::Cli::Presentable)
    expect(data[:'zfs.creation'].raw).to eq(1000)
    expect(data[:'zfs.used'].raw).to eq(2048)
    expect(data[:'zfs.used'].formatted).not_to eq('2048')
  end

  it 'keeps precise output unformatted' do
    dataset = double('dataset', name: 'tank/ct1', properties: { 'used' => '2048' })
    allow(reader).to receive(:read).with(['tank/ct1'], %w[used]).and_return(tree)
    allow(tree).to receive(:each_tree_dataset).and_yield(dataset)
    data = { dataset: 'tank/ct1' }

    helper.add_container_values(data, [:'zfs.used'], precise: true)

    expect(data[:'zfs.used'].formatted).to eq('2048')
  end

  it 'adds property values to arrays of targets' do
    ds1 = double('dataset', name: 'tank/ct1', properties: { 'used' => '1' })
    ds2 = double('dataset', name: 'tank/ct2', properties: { 'used' => '2' })
    allow(reader).to receive(:read).with(%w[tank/ct1 tank/ct2], %w[used]).and_return(tree)
    allow(tree).to receive(:each_tree_dataset).and_yield(ds1).and_yield(ds2)
    rows = [{ dataset: 'tank/ct1' }, { dataset: 'tank/ct2' }]

    helper.add_container_values(rows, [:'zfs.used'])

    expect(rows.map { |row| row[:'zfs.used'].raw }).to eq([1, 2])
  end
end

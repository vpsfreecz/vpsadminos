# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::KernelKeyring do
  subject(:helper) { described_class.new }

  let(:key_user_class) { Struct.new(:nkeys, :nikeys, :qnkeys, :qnbytes) }
  let(:uid_map) { double('uid_map') }
  let(:keyring) { instance_double(OsCtl::Lib::KernelKeyring) }

  before do
    allow(OsCtl::Lib::IdMap).to receive(:from_hash_list).and_return(uid_map)
    allow(OsCtl::Lib::KernelKeyring).to receive(:new).and_return(keyring)
  end

  it 'lists helper parameter names' do
    expect(helper.list_param_names).to include(
      'keyring.nkeys',
      'keyring.nikeys',
      'keyring.qnkeys',
      'keyring.qnbytes'
    )
  end

  it 'ignores selections without keyring-specific columns' do
    data = { uid_map: [] }

    expect(keyring).not_to receive(:for_id_map)

    helper.add_user_values(data, %i[name pool])

    expect(data).to eq(uid_map: [])
  end

  it 'handles symbol columns for a single target hash' do
    allow(keyring).to receive(:for_id_map).with(uid_map).and_return(
      [key_user_class.new(2, 1, 4, 1024), key_user_class.new(3, 2, 5, 2048)]
    )
    data = { uid_map: [{ ns_id: 0, host_id: 100_000, count: 65_536 }] }

    helper.add_user_values(data, %i[keyring.nkeys keyring.qnbytes])

    expect(data[:'keyring.nkeys']).to be_a(OsCtl::Lib::Cli::Presentable)
    expect(data[:'keyring.nkeys'].raw).to eq(5)
    expect(data[:'keyring.qnbytes'].raw).to eq(3072)
    expect(data[:'keyring.qnbytes'].formatted).not_to eq('3072')
  end

  it 'keeps precise output unformatted' do
    allow(keyring).to receive(:for_id_map).with(uid_map).and_return(
      [key_user_class.new(1, 0, 0, 4096)]
    )
    data = { uid_map: [] }

    helper.add_user_values(data, [:'keyring.qnbytes'], precise: true)

    expect(data[:'keyring.qnbytes'].formatted).to eq('4096')
  end

  it 'handles arrays of targets' do
    allow(keyring).to receive(:for_id_map).with(uid_map).and_return(
      [key_user_class.new(1, 0, 0, 128)]
    )
    rows = [{ uid_map: [] }, { uid_map: [] }]

    helper.add_container_values(rows, [:'keyring.nkeys'])

    expect(rows.map { |row| row[:'keyring.nkeys'].raw }).to eq([1, 1])
  end
end

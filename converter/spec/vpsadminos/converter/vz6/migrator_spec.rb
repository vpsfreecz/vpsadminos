# frozen_string_literal: true

require 'spec_helper'
require 'vpsadminos-converter/vz6'

RSpec.describe VpsAdminOS::Converter::Vz6::Migrator do
  let(:vz_ct) { instance_double(VpsAdminOS::Converter::Vz6::Container, ctid: '101', ploop?: ploop) }
  let(:target_ct) { instance_double(VpsAdminOS::Converter::Container, id: '101') }
  let(:state) { instance_double(VpsAdminOS::Converter::Vz6::Migrator::State, vz_ct:, opts: { zfs: use_zfs }) }
  let(:ploop) { false }
  let(:use_zfs) { false }

  describe '.for' do
    it 'chooses Zfs when zfs is enabled' do
      expect(described_class.for(vz_ct, true)).to eq(VpsAdminOS::Converter::Vz6::Migrator::Zfs)
    end

    it 'chooses Ploop for ploop containers without zfs' do
      expect(described_class.for(instance_double(VpsAdminOS::Converter::Vz6::Container, ploop?: true), false))
        .to eq(VpsAdminOS::Converter::Vz6::Migrator::Ploop)
    end

    it 'chooses Simfs otherwise' do
      expect(described_class.for(vz_ct, false)).to eq(VpsAdminOS::Converter::Vz6::Migrator::Simfs)
    end
  end

  describe '.create' do
    it 'rejects already-started migrations' do
      allow(VpsAdminOS::Converter::Vz6::Migrator::State).to receive(:load).with('101').and_return(state)

      expect do
        described_class.create(vz_ct, target_ct, zfs: false)
      end.to raise_error(RuntimeError, 'migration for CT 101 has already been started')
    end

    it 'creates a new state and instantiates the matching backend' do
      allow(VpsAdminOS::Converter::Vz6::Migrator::State).to receive(:load).with('101').and_raise(Errno::ENOENT)
      allow(VpsAdminOS::Converter::Vz6::Migrator::State).to receive(:create) do |src, dst, options|
        expect(src).to eq(vz_ct)
        expect(dst).to eq(target_ct)
        expect(options).to eq(zfs: false)
      end.and_return(state)
      allow(VpsAdminOS::Converter::Vz6::Migrator::Simfs).to receive(:new).with(state).and_return(:migrator)

      expect(described_class.create(vz_ct, target_ct, zfs: false)).to eq(:migrator)
    end
  end

  describe '.load' do
    let(:use_zfs) { true }

    it 'loads state and instantiates the matching backend' do
      allow(VpsAdminOS::Converter::Vz6::Migrator::State).to receive(:load).with('101').and_return(state)
      allow(VpsAdminOS::Converter::Vz6::Migrator::Zfs).to receive(:new).with(state).and_return(:loaded)

      expect(described_class.load('101')).to eq(:loaded)
    end
  end
end

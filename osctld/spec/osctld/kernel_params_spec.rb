# frozen_string_literal: true

require 'osctld/kernel_params'

RSpec.describe OsCtld::KernelParams do
  subject(:params) { fresh_singleton(described_class) }

  context 'with defaults' do
    before do
      allow(File).to receive(:read).with('/proc/cmdline').and_return('quiet splash root=/dev/vda')
    end

    it 'checks presence and reads key-value parameters with defaults' do
      expect(params).to include('quiet')
      expect(params.read_kv('osctl.pools', '1')).to eq('1')
      expect(params.import_pools?).to be(true)
      expect(params.autostart_cts?).to be(true)
    end
  end

  context 'with explicit kernel options' do
    before do
      allow(File).to receive(:read).with('/proc/cmdline').and_return(
        'root=/dev/vda osctl.pools=0 osctl.autostart=0'
      )
    end

    it 'disables pool import and autostart' do
      expect(params.import_pools?).to be(false)
      expect(params.autostart_cts?).to be(false)
    end

    it 'caches results per instance' do
      expect(params.import_pools?).to be(false)

      params.params.delete('osctl.pools=0')

      expect(params.import_pools?).to be(false)
    end
  end
end

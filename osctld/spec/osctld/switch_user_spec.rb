# frozen_string_literal: true

require 'osctld/switch_user'

RSpec.describe OsCtld::SwitchUser do
  describe '.attach_namespace_if_present' do
    it 'joins an existing namespace path' do
      sys = double

      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/proc/123/ns/tracing').and_return(true)

      expect(sys).to receive(:setns_path).with('/proc/123/ns/tracing', 0)

      described_class.send(:attach_namespace_if_present, sys, 123, 'tracing')
    end

    it 'ignores missing namespace paths for compatibility with older kernels' do
      sys = double

      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/proc/123/ns/lsm').and_return(false)

      expect(sys).not_to receive(:setns_path)

      described_class.send(:attach_namespace_if_present, sys, 123, 'lsm')
    end

    it 'does nothing when no pid is provided' do
      sys = double

      expect(sys).not_to receive(:setns_path)

      described_class.send(:attach_namespace_if_present, sys, nil, 'tracing')
    end
  end
end

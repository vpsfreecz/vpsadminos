# frozen_string_literal: true

require 'osctld/switch_user'

RSpec.describe OsCtld::SwitchUser do
  def namespace_sys
    Class.new do
      attr_reader :setns_paths

      def initialize
        @setns_paths = []
      end

      def setns_path(path, flags)
        setns_paths << [path, flags]
      end
    end.new
  end

  describe '.attach_namespace_if_present' do
    it 'joins an existing namespace path' do
      sys = namespace_sys

      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/proc/123/ns/tracing').and_return(true)

      described_class.send(:attach_namespace_if_present, sys, 123, 'tracing')

      expect(sys.setns_paths).to eq([['/proc/123/ns/tracing', 0]])
    end

    it 'ignores missing namespace paths for compatibility with older kernels' do
      sys = namespace_sys

      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/proc/123/ns/lsm').and_return(false)

      described_class.send(:attach_namespace_if_present, sys, 123, 'lsm')

      expect(sys.setns_paths).to be_empty
    end

    it 'does nothing when no pid is provided' do
      sys = namespace_sys

      described_class.send(:attach_namespace_if_present, sys, nil, 'tracing')

      expect(sys.setns_paths).to be_empty
    end
  end
end

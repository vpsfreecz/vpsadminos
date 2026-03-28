# frozen_string_literal: true

require 'osctld/daemon'

RSpec.describe OsCtld::Daemon do
  before do
    described_class.class_variable_set(:@@instance, nil)
  end

  after do
    described_class.class_variable_set(:@@instance, nil)
  end

  describe '.create' do
    it 'rejects duplicate creation and keeps the original instance' do
      daemon = instance_double(described_class)

      allow(described_class).to receive(:new).with('daemon.yml').and_return(daemon)

      expect(described_class.create('daemon.yml')).to be(daemon)
      expect(described_class.get).to be(daemon)
      expect { described_class.create('daemon.yml') }.to raise_error(
        RuntimeError,
        'Daemon already instantiated'
      )
      expect(described_class.get).to be(daemon)
      expect(described_class).to have_received(:new).once
    end
  end
end

# frozen_string_literal: true

require 'osctld/command'

RSpec.describe OsCtld::Command do
  around do |example|
    snapshot = described_class.class_variable_get(:@@commands).transform_values(&:dup)
    example.run
  ensure
    described_class.class_variable_set(:@@commands, snapshot)
  end

  it 'registers and finds commands by handle' do
    klass = Class.new

    described_class.register(:spec_ping, klass)

    expect(described_class.find(:spec_ping)).to eq(klass)
  end

  it 'rejects duplicate command handles' do
    described_class.register(:spec_ping, Class.new)

    expect do
      described_class.register(:spec_ping, Class.new)
    end.to raise_error(/already handled/)
  end

  it 'allocates monotonically increasing command ids' do
    first = described_class.get_id
    second = described_class.get_id

    expect(second).to be > first
  end
end

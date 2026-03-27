# frozen_string_literal: true

require 'osctld/container/adaptor'

AdaptorSpecContainer = Struct.new(:log_type, keyword_init: true)

RSpec.describe OsCtld::Container::Adaptor do
  let(:ct) { instance_double(AdaptorSpecContainer, log_type: 'ct=tank:ct1') }

  around do |example|
    original = described_class.instance_variable_get(:@adaptors)
    described_class.instance_variable_set(:@adaptors, nil)
    example.run
    described_class.instance_variable_set(:@adaptors, original)
  end

  it 'returns the original config when no adaptors are registered' do
    config = { 'distribution' => 'almalinux' }

    expect(described_class.adapt(ct, config)).to be(config)
  end

  it 'chains adaptors in registration order' do
    first = Class.new do
      def initialize(_ct, config)
        @config = config
      end

      def adapt
        @config.merge('steps' => (@config['steps'] || []) + ['first'])
      end
    end

    second = Class.new do
      def initialize(_ct, config)
        @config = config
      end

      def adapt
        @config.merge('steps' => (@config['steps'] || []) + ['second'])
      end
    end

    described_class.register(:first, first)
    described_class.register(:second, second)

    expect(described_class.adapt(ct, {})).to eq('steps' => %w[first second])
  end

  it 'passes the container and current config to each adaptor' do
    received = []

    first = Class.new do
      define_method(:initialize) do |ct, config|
        received << [ct, config.dup]
        @config = config
      end

      def adapt
        @config.merge('step' => 1)
      end
    end

    second = Class.new do
      define_method(:initialize) do |ct, config|
        received << [ct, config.dup]
        @config = config
      end

      def adapt
        @config
      end
    end

    described_class.register(:first, first)
    described_class.register(:second, second)

    described_class.adapt(ct, 'distribution' => 'almalinux')

    expect(received).to eq(
      [
        [ct, { 'distribution' => 'almalinux' }],
        [ct, { 'distribution' => 'almalinux', 'step' => 1 }]
      ]
    )
  end
end

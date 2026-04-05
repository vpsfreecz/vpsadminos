# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Cli::Command do
  it 'configures stdout logging during initialization' do
    allow(OsCtl::Lib::Logger).to receive(:setup)

    build_command(described_class)

    expect(OsCtl::Lib::Logger).to have_received(:setup).with(:stdout)
  end

  describe '.run' do
    let(:klass) do
      Class.new(described_class) do
        class << self
          attr_reader :instances
        end

        @instances = []

        def initialize(*)
          super
          self.class.instances << self
        end

        def execute
          @executed = true
        end

        attr_reader :executed
      end
    end

    it 'instantiates the command and dispatches to the requested method' do
      allow(OsCtl::Lib::Logger).to receive(:setup)

      described_class.run(klass, :execute).call({}, {}, [])

      expect(klass.instances.last.executed).to be(true)
    end
  end
end

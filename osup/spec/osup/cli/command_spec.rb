# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsUp::Cli::Command do
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

    it 'enables stdout logging in debug mode' do
      allow(OsCtl::Lib::Logger).to receive(:setup)

      described_class.run(klass, :execute).call({ debug: true }, {}, [])

      expect(OsCtl::Lib::Logger).to have_received(:setup).with(:stdout)
    end

    it 'disables logging when debug mode is off' do
      allow(OsCtl::Lib::Logger).to receive(:setup)

      described_class.run(klass, :execute).call({ debug: false }, {}, [])

      expect(OsCtl::Lib::Logger).to have_received(:setup).with(:none)
    end

    it 'instantiates the command and invokes the selected method' do
      described_class.run(klass, :execute).call({ debug: false }, {}, [])

      expect(klass.instances.last.executed).to be(true)
    end
  end
end

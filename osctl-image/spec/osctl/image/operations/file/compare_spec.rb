# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::File::Compare do
  it 'returns true when cmp exits successfully' do
    op_class = Class.new(described_class) do
      class << self
        attr_accessor :result, :seen
      end

      def syscmd(cmd, **opts)
        self.class.seen = [cmd, opts]
        self.class.result
      end
    end
    op_class.result = command_result('', exitstatus: 0)

    expect(op_class.new('/tmp/a', '/tmp/b').execute).to be(true)
    expect(op_class.seen).to eq(['cmp -s "/tmp/a" "/tmp/b"', { valid_rcs: [1, 2] }])
  end

  it 'returns false when cmp reports a difference' do
    op_class = Class.new(described_class) do
      class << self
        attr_accessor :result
      end

      def syscmd(*, **)
        self.class.result
      end
    end
    op_class.result = command_result('', exitstatus: 1)

    expect(op_class.new('/tmp/a', '/tmp/b').execute).to be(false)
  end

  it 'does not raise on other valid non-zero comparison exit codes' do
    op_class = Class.new(described_class) do
      class << self
        attr_accessor :result
      end

      def syscmd(*, **)
        self.class.result
      end
    end
    op_class.result = command_result('', exitstatus: 2)

    op = op_class.new('/tmp/a', '/tmp/b')

    expect { op.execute }.not_to raise_error
    expect(op.execute).to be(false)
  end
end

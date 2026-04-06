# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Hook do
  it 'registers hooks' do
    described_class.register(:custom)

    expect(described_class.instance_variable_get(:@hooks)).to include(custom: [])
  end

  it 'subscribes to registered hooks' do
    described_class.register(:custom)
    block = proc { :ok }

    expect(described_class.subscribe(:custom, &block)).to be_nil
    expect(described_class.instance_variable_get(:@hooks)[:custom]).to include(block)
  end

  it 'raises when subscribing to an unknown hook' do
    expect do
      described_class.subscribe(:missing) { nil }
    end.to raise_error(RuntimeError, 'hook :missing not registered')
  end

  it 'chains return_value through subscribers' do
    described_class.register(:custom)
    described_class.subscribe(:custom) { |value:, return_value:| [value, return_value] }
    described_class.subscribe(:custom) { |value:, return_value:| [value, return_value] }

    expect(described_class.call(:custom, kwargs: { value: 1 })).to eq([1, [1, nil]])
  end
end

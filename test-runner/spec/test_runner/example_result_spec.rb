# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::ExampleResult do
  let(:group) { instance_double(TestRunner::ExampleGroup, message: 'group') }
  let(:noop) { proc {} }

  it 'treats successful regular examples as successes' do
    example = TestRunner::Example.new(group, 'works', &noop)
    result = described_class.new(example, 0.1)

    expect(result).to be_success
    expect(result).not_to be_failure
  end

  it 'treats failed regular examples as failures' do
    example = TestRunner::Example.new(group, 'fails', &noop)
    result = described_class.new(example, 0.1, RuntimeError.new('boom'))

    expect(result).to be_failure
  end

  it 'treats pending examples as successful only when they fail' do
    example = TestRunner::Example.new(group, 'pending', pending: true, &noop)

    expect(described_class.new(example, 0.1, RuntimeError.new('boom'))).to be_success
    expect(described_class.new(example, 0.1)).to be_failure
  end

  it 'treats skipped examples as successes' do
    example = TestRunner::Example.new(group, 'skipped', skip: true, &noop)

    expect(described_class.new(example, 0.1)).to be_success
  end

  it 'returns titles and human-readable errors' do
    example = TestRunner::Example.new(group, 'fails', &noop)
    pending_example = TestRunner::Example.new(group, 'pending', pending: 'later', &noop)
    skipped_example = TestRunner::Example.new(group, 'skipped', skip: 'later', &noop)

    expect(described_class.new(example, 0.1, RuntimeError.new('boom')).title).to eq('group fails')
    expect(described_class.new(example, 0.1, RuntimeError.new('boom')).error).to eq('boom')
    expect(described_class.new(pending_example, 0.1).error).to include('unexpectedly succeeded')
    expect(described_class.new(skipped_example, 0.1).error).to eq('later')
  end

  it 'serializes to hashes' do
    example = TestRunner::Example.new(group, 'works', &noop)
    result = described_class.new(example, 0.1)

    expect(result.to_h(script: 'default', progress: 1, total: 2)).to include(
      'type' => 'example',
      'script' => 'default',
      'example' => 'group works',
      'progress' => 1,
      'total' => 2,
      'success' => true
    )
  end
end

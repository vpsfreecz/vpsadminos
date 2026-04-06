# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Example do
  let(:group) { instance_double(TestRunner::ExampleGroup, message: 'group') }
  let(:noop) { proc {} }

  it 'reports pending, skipped, and evaluable state' do
    pending_example = described_class.new(group, 'pending', pending: true, &noop)
    skipped_example = described_class.new(group, 'skipped', skip: true, &noop)

    expect(pending_example.pending?).to be(true)
    expect(skipped_example.skip?).to be(true)
    expect(skipped_example.evaluate?).to be(false)
  end

  it 'builds the full message and reason' do
    example = described_class.new(group, 'works', pending: 'later', &noop)

    expect(example.full_message).to eq('group works')
    expect(example.reason).to eq('later')
  end

  it 'evaluates successful examples' do
    example = described_class.new(group, 'works') { true }

    result = example.evaluate

    expect(result).to be_success
  end

  it 'captures expectation failures' do
    example = described_class.new(group, 'fails') do
      raise RSpec::Expectations::ExpectationNotMetError, 'expected failure'
    end

    result = example.evaluate

    expect(result).to be_failure
    expect(result.exception).to be_a(RSpec::Expectations::ExpectationNotMetError)
  end

  it 'captures regular exceptions' do
    example = described_class.new(group, 'errors') { raise 'boom' }

    result = example.evaluate

    expect(result).to be_failure
    expect(result.exception.message).to eq('boom')
  end

  it 'preserves skipped examples' do
    example = described_class.new(group, 'skip me', skip: 'later', &noop)

    expect(example.skip?).to eq('later')
    expect(example.reason).to eq('later')
  end
end

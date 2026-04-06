# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestScriptResult do
  let(:script) { build_test.expect_failure ? nil : build_test.test_scripts['default'] }

  it 'reports success and expectation state' do
    script = build_test.test_scripts['default']
    result = described_class.new(script, true, 0.1)

    expect(result).to be_successful
    expect(result).not_to be_failed
    expect(result).to be_expected_result
  end

  it 'reports unexpected results for expected-failure scripts that succeed' do
    test = build_test(expect_failure: true)
    script = test.test_scripts['default']
    result = described_class.new(script, true, 0.1)

    expect(result).to be_unexpected_result
  end

  it 'serializes and deserializes hashes and json' do
    script = build_test.test_scripts['default']
    result = described_class.new(script, true, 0.1)

    hash = result.to_h
    round_trip = described_class.from_h(script, JSON.parse(result.to_json))

    expect(hash).to include('type' => 'script', 'script' => 'default')
    expect(round_trip.successful?).to be(true)
    expect(round_trip.test_script).to eq(script)
  end
end

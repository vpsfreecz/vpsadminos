# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestResult do
  let(:test) { build_test(expect_failure: false) }
  let(:script) { test.test_scripts['default'] }

  it 'reports success and expectation state' do
    result = described_class.new(test, [TestRunner::TestScriptResult.new(script, true, 0.1)], true, 0.2, '/tmp/state')

    expect(result).to be_successful
    expect(result).not_to be_failed
    expect(result).to be_expected_result
  end

  it 'treats failed expected-failure tests as expected results' do
    failing_test = build_test(expect_failure: true)
    result = described_class.new(
      failing_test,
      [TestRunner::TestScriptResult.new(failing_test.test_scripts['default'], false, 0.1)],
      false,
      0.2,
      '/tmp/state'
    )

    expect(result).to be_expected_result
  end

  it 'always treats a guest kernel failure as unexpected' do
    failing_test = build_test(expect_failure: true)
    result = described_class.new(
      failing_test,
      [TestRunner::TestScriptResult.new(failing_test.test_scripts['default'], false, 0.1)],
      false,
      0.2,
      '/tmp/state',
      kernel_failure: true
    )

    expect(result).to be_kernel_failure
    expect(result).to be_failed
    expect(result).to be_unexpected_result
  end

  it 'serializes and deserializes hashes and json' do
    result = described_class.new(test, [TestRunner::TestScriptResult.new(script, true, 0.1)], true, 0.2, '/tmp/state')

    hash = result.to_h
    round_trip = described_class.from_h(test, test.test_scripts, JSON.parse(result.to_json))

    expect(hash).to include('type' => 'test', 'test' => 'suite/example')
    expect(round_trip.successful?).to be(true)
    expect(round_trip).not_to be_kernel_failure
    expect(round_trip.script_results.first.test_script).to eq(script)
  end
end

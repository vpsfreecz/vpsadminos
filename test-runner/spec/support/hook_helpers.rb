# frozen_string_literal: true

ORIGINAL_TEST_RUNNER_HOOKS =
  TestRunner::Hook.instance_variable_get(:@hooks).transform_values(&:dup).freeze

RSpec.configure do |config|
  config.before do
    restored = ORIGINAL_TEST_RUNNER_HOOKS.transform_values { |_| [] }
    TestRunner::Hook.instance_variable_set(:@hooks, restored)
  end
end

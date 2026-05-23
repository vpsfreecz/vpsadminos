# frozen_string_literal: true

module FakeTestHelpers
  def build_test(
    path: 'suite/example',
    type: 'test',
    template: nil,
    template_args: {},
    test_args: {},
    name: 'example',
    description: 'Example test',
    attempts: 1,
    expect_failure: false,
    test_script_jobs: 1,
    tags: [],
    labels: {},
    scripts: { 'default' => {} }
  )
    TestRunner::Test.new(
      path:,
      type:,
      template:,
      template_args:,
      test_args:,
      name:,
      description:,
      attempts:,
      expect_failure:,
      test_script_jobs:,
      tags:,
      labels:,
      test_scripts: scripts
    )
  end

  def build_test_script(test = build_test, name: 'default')
    test.test_scripts.fetch(name)
  end
end

RSpec.configure do |config|
  config.include FakeTestHelpers
end

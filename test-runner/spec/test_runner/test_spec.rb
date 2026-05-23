# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Test do
  it 'exposes test metadata' do
    test = build_test(
      path: 'suite/example',
      name: 'example',
      description: 'An example',
      attempts: 2,
      expect_failure: true,
      test_script_jobs: 3,
      tags: ['smoke'],
      labels: { 'tier' => '1' }
    )

    expect(test.path).to eq('suite/example')
    expect(test.name).to eq('example')
    expect(test.description).to eq('An example')
    expect(test.attempts).to eq(2)
    expect(test.expect_failure).to be(true)
    expect(test.test_script_jobs).to eq(3)
    expect(test.tags).to eq(['smoke'])
    expect(test.labels).to eq('tier' => '1')
  end

  it 'collapses a lone default script to a singleton path' do
    test = build_test

    expect(test.test_scripts['default'].singleton?).to be(true)
    expect(test.test_scripts['default'].path).to eq('suite/example')
  end

  it 'reports templates and their file paths' do
    template = build_test(type: 'template', template: 'templates/base')
    regular = build_test(path: 'suite/example')

    expect(template.template?).to be(true)
    expect(template.file_path).to eq('templates/base.nix')
    expect(regular.file_path).to eq('suite/example.nix')
  end
end

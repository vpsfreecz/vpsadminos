# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestScript do
  subject(:script) { test.test_scripts['smoke'] }

  let(:test) do
    build_test(
      path: 'suite/example',
      description: 'Parent description',
      expect_failure: true,
      tags: ['smoke'],
      labels: { 'tier' => '1' },
      scripts: {
        'smoke' => {
          'description' => nil,
          'expectFailure' => nil,
          'attempts' => 2,
          'tags' => ['fast'],
          'labels' => { 'distro' => 'nixos' }
        }
      }
    )
  end

  it 'builds script paths with a suffix' do
    expect(script.path).to eq('suite/example#smoke')
  end

  it 'inherits description and expect_failure when not overridden' do
    expect(script.description).to eq('Parent description')
    expect(script.expect_failure).to be(true)
  end

  it 'uses script attempts when configured' do
    expect(script.attempts).to eq(2)
  end

  it 'merges tags and labels' do
    expect(script.tags).to eq(%w[smoke fast])
    expect(script.labels).to eq('tier' => '1', 'distro' => 'nixos')
  end

  it 'matches path globs' do
    expect(script.path_matches?('suite/*')).to be(true)
  end

  it 'can become a singleton script' do
    script.set_singleton

    expect(script.singleton?).to be(true)
    expect(script.path).to eq('suite/example')
  end
end

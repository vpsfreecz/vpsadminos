# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Cli::FilterExpression do
  def pass?(expr, tags: [], labels: {})
    script = instance_double(TestRunner::TestScript, tags:, labels:)

    described_class.new(expr).pass?(script)
  end

  it 'matches tag equality' do
    expect(pass?('tag=ci', tags: %w[ci storage])).to be(true)
    expect(pass?('tag=ci', tags: %w[storage])).to be(false)
  end

  it 'matches tag inequality' do
    expect(pass?('tag!=manual', tags: %w[ci storage])).to be(true)
    expect(pass?('tag!=manual', tags: %w[ci manual])).to be(false)
  end

  it 'matches label equality' do
    expect(pass?('runtime=long', labels: { 'runtime' => 'long' })).to be(true)
    expect(pass?('runtime=long', labels: { 'runtime' => 'short' })).to be(false)
  end

  it 'matches label inequality' do
    expect(pass?('runtime!=long', labels: { 'runtime' => 'short' })).to be(true)
    expect(pass?('runtime!=long', labels: { 'runtime' => 'long' })).to be(false)
  end

  it 'matches conjunctions' do
    expect(
      pass?('tag=ci && runtime=short', tags: ['ci'], labels: { 'runtime' => 'short' })
    ).to be(true)
    expect(
      pass?('tag=ci && runtime=short', tags: ['ci'], labels: { 'runtime' => 'long' })
    ).to be(false)
  end

  it 'matches disjunctions' do
    expect(pass?('tag=vps || tag=storage', tags: ['storage'])).to be(true)
    expect(pass?('tag=vps || tag=storage', tags: ['network'])).to be(false)
  end

  it 'gives conjunction higher precedence than disjunction' do
    expect(pass?('tag=a || tag=b && tag=c', tags: ['a'])).to be(true)
  end

  it 'uses parentheses to override precedence' do
    expect(pass?('(tag=a || tag=b) && tag=c', tags: ['a'])).to be(false)
  end

  it 'matches mixed tag and label expressions' do
    expr = 'tag=ci && (tag=storage || component=zfs) && runtime!=long'

    expect(
      pass?(expr, tags: %w[ci network], labels: { 'component' => 'zfs', 'runtime' => 'short' })
    ).to be(true)
  end

  it 'raises on invalid expressions' do
    [
      '',
      'tag=',
      'tag',
      'tag=ci &&',
      'tag=ci ||| tag=vps',
      '(tag=ci',
      'tag=ci)'
    ].each do |expr|
      expect do
        described_class.new(expr)
      end.to raise_error(GLI::BadCommandLine, /^Invalid filter expression/)
    end
  end
end

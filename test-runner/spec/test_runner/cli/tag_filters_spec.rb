# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Cli::TagFilters do
  it 'matches required tags' do
    script = instance_double(TestRunner::TestScript, tags: %w[smoke fast])

    expect(described_class.new(['smoke']).pass?(script)).to be(true)
  end

  it 'rejects negated tags' do
    script = instance_double(TestRunner::TestScript, tags: %w[smoke slow])

    expect(described_class.new(['^slow']).pass?(script)).to be(false)
  end

  it 'combines positive and negative tags' do
    script = instance_double(TestRunner::TestScript, tags: %w[smoke fast])

    expect(described_class.new(['smoke', '^slow']).pass?(script)).to be(true)
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Prometheus::Client::Registry do
  it 'duplicates the metric hash and mutex without sharing registry state' do
    registry = described_class.new
    registry.gauge(:demo_metric, docstring: 'demo').set(1)

    copy = registry.clone

    expect(copy.instance_variable_get(:@metrics)).not_to equal(registry.instance_variable_get(:@metrics))
    expect(copy.instance_variable_get(:@mutex)).not_to equal(registry.instance_variable_get(:@mutex))

    copy.gauge(:copy_only_metric, docstring: 'copy').set(2)

    expect(registry.exist?(:copy_only_metric)).to be(false)
    expect(copy.exist?(:copy_only_metric)).to be(true)
  end
end

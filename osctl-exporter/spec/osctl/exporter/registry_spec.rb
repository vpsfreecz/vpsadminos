# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Registry do
  it 'writes to a cloned registry and swaps it only after a successful block' do
    registry = described_class.new
    gauge = registry.gauge(:demo_metric, docstring: 'demo')
    gauge.set(1)

    registry.atomic_replace do |new_registry|
      new_registry.get(:demo_metric).set(2)
      expect(metric_values(registry.get(:demo_metric))).to eq({ {} => 1.0 })

      registry.gauge(:new_metric, docstring: 'new').set(3)
      expect(registry.exist?(:new_metric)).to be(false)
    end

    expect(metric_values(registry.get(:demo_metric))).to eq({ {} => 2.0 })
    expect(metric_values(registry.get(:new_metric))).to eq({ {} => 3.0 })
  end

  it 'keeps the exported registry stable when the replacement block raises' do
    registry = described_class.new
    registry.gauge(:demo_metric, docstring: 'demo').set(1)

    expect do
      registry.atomic_replace do |new_registry|
        new_registry.get(:demo_metric).set(9)
        raise 'boom'
      end
    end.to raise_error(RuntimeError, 'boom')

    expect(metric_values(registry.get(:demo_metric))).to eq({ {} => 1.0 })
  end
end

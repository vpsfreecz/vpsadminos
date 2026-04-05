# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::MultiRegistry do
  it 'creates and exposes multiple registries as one' do
    multi = described_class.new
    reg_a = multi.new_registry(:a)
    reg_b = multi.new_registry(:b)

    reg_a.gauge(:metric_a, docstring: 'a').set(1)
    reg_b.gauge(:metric_b, docstring: 'b').set(2)

    expect(multi.exist?(:metric_a)).to be(true)
    expect(multi.exist?(:metric_b)).to be(true)
    expect(metric_values(multi.get(:metric_a))).to eq({ {} => 1.0 })
    expect(metric_values(multi.get(:metric_b))).to eq({ {} => 2.0 })
    expect(multi.metrics.map(&:name)).to contain_exactly(:metric_a, :metric_b)
  end

  it 'rejects write operations on the aggregate registry' do
    multi = described_class.new

    expect do
      multi.gauge(:unsupported, docstring: 'nope')
    end.to raise_error(RuntimeError, 'not supported on MultiRegistry')
  end
end

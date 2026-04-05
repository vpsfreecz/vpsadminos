# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Formats::Json do
  it 'serializes unlabeled, labeled, and multiple metrics' do
    registry = Prometheus::Client::Registry.new
    unlabeled = registry.gauge(:plain_metric, docstring: 'plain')
    labeled = registry.gauge(:labeled_metric, docstring: 'labeled', labels: %i[pool id])

    unlabeled.set(1)
    labeled.set(2, labels: { pool: 'tank', id: 'ct1' })
    labeled.set(3, labels: { pool: 'tank', id: 'ct2' })

    parsed = JSON.parse(described_class.marshal(registry))

    expect(parsed['plain_metric']).to eq([{ 'labels' => {}, 'value' => 1.0 }])
    expect(parsed['labeled_metric']).to contain_exactly(
      { 'labels' => { 'pool' => 'tank', 'id' => 'ct1' }, 'value' => 2.0 },
      { 'labels' => { 'pool' => 'tank', 'id' => 'ct2' }, 'value' => 3.0 }
    )
  end
end

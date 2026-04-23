# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Exporter::Collectors::Base do
  let(:collector_class) do
    Class.new(described_class) do
      attr_reader :seen_client

      def setup
        add_metric(:dynamic_metric, :gauge, :dynamic_metric, docstring: 'dynamic')
        @static_metric = registry.gauge(:static_metric, docstring: 'static')
      end

      def collect(client)
        @seen_client = client
        @dynamic_metric.set(7)
      end
    end
  end

  it 'registers auto metrics and refreshes them on each collection' do
    registry = OsCtl::Exporter::Registry.new
    collector = collector_class.new(instance_double(OsCtl::Exporter::Collector), registry)

    expect(collector.send(:metric_configs).keys).to eq([:dynamic_metric])

    collect_with_registry_swap(registry, collector, :client_one)
    first_metric = collector.instance_variable_get(:@dynamic_metric)

    expect(collector.seen_client).to eq(:client_one)
    expect(metric_values(registry.get(:dynamic_metric))).to eq({ {} => 7.0 })

    collect_with_registry_swap(registry, collector, :client_two)
    second_metric = collector.instance_variable_get(:@dynamic_metric)

    expect(second_metric).not_to equal(first_metric)
    expect(collector.seen_client).to eq(:client_two)
  end
end

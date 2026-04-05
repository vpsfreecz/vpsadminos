# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Prometheus::Middleware::Exporter do
  it 'includes the custom JSON format' do
    expect(described_class::FORMATS).to include(OsCtl::Exporter::Formats::Json)
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'rack'

RSpec.describe Rack::Builder do
  it 'loads the rack app, starts the collector manager, and serves OK at /' do
    allow(OsCtl::Exporter::Collector).to receive(:start)
    app, = described_class.parse_file(File.join(REPO_ROOT, 'osctl-exporter', 'config.ru'))

    response = Rack::MockRequest.new(app).get('/')

    expect(OsCtl::Exporter::Collector).to have_received(:start)
    expect(response.status).to eq(200)
    expect(response.body).to eq('OK')
  end
end

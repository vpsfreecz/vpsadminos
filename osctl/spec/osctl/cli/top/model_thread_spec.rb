# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Tui::ModelThread do
  it 'measures model data, increments generations, and switches modes' do
    model = double(
      'model',
      mode: :realtime,
      'mode=': nil,
      measure: nil,
      data: { containers: [] },
      iostat_enabled?: true,
      containers: []
    )
    thread = described_class.new(model, 0.01)

    thread.send(:measure)
    data, _time, generation = thread.get_data
    expect(data).to eq(containers: [])
    expect(generation).to eq(1)

    thread.send(:measure, mode: :cumulative)
    expect(thread.mode).to eq(:cumulative)
    expect(thread.generation).to eq(2)
  end
end

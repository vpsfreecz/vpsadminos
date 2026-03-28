# frozen_string_literal: true

require 'osctld/container_control/result'

RSpec.describe OsCtld::ContainerControl::Result do
  it 'maps successful runner results to data-bearing results' do
    result = described_class.from_runner(status: true, output: { state: 'running' })

    expect(result.ok?).to be(true)
    expect(result.data).to eq(state: 'running')
  end

  it 'maps failed runner results to error messages' do
    result = described_class.from_runner(status: false, message: 'failed')

    expect(result.ok?).to be(false)
    expect(result.message).to eq('failed')
  end
end

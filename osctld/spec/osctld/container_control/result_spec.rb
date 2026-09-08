# frozen_string_literal: true

require 'osctld/container_control/result'

RSpec.describe OsCtld::ContainerControl::Result do
  %i[setup execution response].each do |stage|
    it "categorizes #{stage} failures without including diagnostics in the caller error" do
      error = RuntimeError.new('private detail')
      error.set_backtrace(['private.rb:123'])
      payload = described_class.failure_payload(error, stage:)
      result = described_class.from_runner(payload)

      expect(result.ok?).to be(false)
      expect(result.user_runner?).to eq(stage == :setup)
      expect(result.message).to eq("helper #{stage} failed (RuntimeError)")
      expect(payload.fetch(:diagnostic)).to include('private detail', 'private.rb:123')
    end
  end

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

  it 'preserves the user runner marker from failed runner results' do
    result = described_class.from_runner(status: false, message: 'failed', user_runner: true)

    expect(result.ok?).to be(false)
    expect(result.message).to eq('failed')
    expect(result.user_runner?).to be(true)
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestEvaluator, '#start_all' do
  it 'starts all machine values' do
    evaluator = described_class.allocate
    machines = {
      'a' => instance_spy(FakeMachine, start: nil, wait_for_boot: nil),
      'b' => instance_spy(FakeMachine, start: nil, wait_for_boot: nil)
    }
    evaluator.instance_variable_set(:@machines, machines)

    evaluator.start_all

    expect(machines['a']).to have_received(:start).with(wait_for_boot: false)
    expect(machines['b']).to have_received(:start).with(wait_for_boot: false)
    expect(machines['a']).to have_received(:wait_for_boot)
    expect(machines['b']).to have_received(:wait_for_boot)
  end
end

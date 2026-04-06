# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::TestEvaluator, '#start_all' do
  it 'starts all machine values' do
    evaluator = described_class.allocate
    machines = {
      'a' => instance_spy(FakeMachine, start: nil),
      'b' => instance_spy(FakeMachine, start: nil)
    }
    evaluator.instance_variable_set(:@machines, machines)

    evaluator.start_all

    expect(machines['a']).to have_received(:start)
    expect(machines['b']).to have_received(:start)
  end
end

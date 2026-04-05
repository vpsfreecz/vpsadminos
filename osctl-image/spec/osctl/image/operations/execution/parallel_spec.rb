# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Operations::Execution::Parallel do
  it 'returns successful and failed job results' do
    op = described_class.new(1)
    op.add('first') { 1 }
    op.add('second') { raise 'boom' }

    results = op.execute

    expect(results.map(&:obj)).to eq(%w[first second])
    expect(results.map(&:status)).to eq([true, false])
    expect(results.first.return_value).to eq(1)
    expect(results.last.exception.message).to eq('boom')
  end

  it 'clears queued jobs when stopped' do
    op = described_class.new(1)
    op.add('first') { 1 }
    op.add('second') { 2 }

    op.stop

    expect(op.execute).to eq([])
  end
end

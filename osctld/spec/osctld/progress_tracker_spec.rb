# frozen_string_literal: true

require 'osctld/progress_tracker'

RSpec.describe OsCtld::ProgressTracker do
  subject(:tracker) { described_class.new(progress: 1, total: 2) }

  it 'adds to the total and increments progress by default' do
    tracker.add_total(3)

    expect(tracker.progress_line('copying')).to eq('[2/5] copying')
  end

  it 'does not increment when increment_by is nil' do
    expect(tracker.progress_line('waiting', increment_by: nil)).to eq('[1/2] waiting')
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/loadavg'

RSpec.describe OsCtl::Lib::LoadAvg do
  it 'parses averages, runnable tasks, total tasks, and the last pid' do
    with_tmpdir do |dir|
      path = File.join(dir, 'loadavg')
      File.write(path, "0.10 1.20 2.30 3/99 1234\n")

      loadavg = described_class.new(path:)

      expect(loadavg.avg).to eq(1 => 0.10, 5 => 1.20, 15 => 2.30)
      expect(loadavg.runnable).to eq(3)
      expect(loadavg.total).to eq(99)
      expect(loadavg.last_pid).to eq(1234)
      expect(loadavg.to_a).to eq([0.10, 1.20, 2.30])
    end
  end
end

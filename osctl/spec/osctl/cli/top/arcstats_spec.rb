# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::ArcStats do
  it 'parses arcstats files and exposes derived hit rates' do
    with_tempdir do |dir|
      path = File.join(dir, 'arcstats')
      File.write(path, <<~TEXT)
        header
        header
        hits 4 80
        misses 4 20
        l2_hits 4 9
        l2_misses 4 1
        c_max 4 10
        c 4 8
        size 4 7
        l2_size 4 6
        l2_asize 4 5
      TEXT

      stats = described_class.new(path)

      expect(stats.hit_rate).to eq(80.0)
      expect(stats.l2_hit_rate).to eq(90.0)
      expect(stats).to respond_to(:hits)
      expect(stats.hits).to eq(80)
    end
  end
end

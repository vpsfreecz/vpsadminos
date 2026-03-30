# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/meminfo'

RSpec.describe OsCtl::Lib::MemInfo do
  it 'parses memory and swap values and caches parsed entries' do
    with_tmpdir do |dir|
      path = File.join(dir, 'meminfo')
      File.write(path, <<~MEMINFO)
        MemTotal:       4096 kB
        MemFree:        1024 kB
        Buffers:         128 kB
        Cached:          256 kB
        SwapCached:       64 kB
        SwapTotal:      2048 kB
        SwapFree:       1024 kB
      MEMINFO

      meminfo = described_class.new(path)

      expect(meminfo.total).to eq(4096)
      expect(meminfo.free).to eq(1216)
      expect(meminfo.free(false)).to eq(1024)
      expect(meminfo.used).to eq(2880)
      expect(meminfo.cached).to eq(256)
      expect(meminfo.buffers).to eq(128)
      expect(meminfo.swap_total).to eq(2048)
      expect(meminfo.swap_free).to eq(1024)
      expect(meminfo.swap_used).to eq(1024)
      expect(meminfo.swap_cached).to eq(64)

      meminfo.instance_variable_set(
        :@content,
        meminfo.instance_variable_get(:@content).sub('Cached:          256 kB', 'Cached:         4096 kB')
      )

      expect(meminfo.cached).to eq(256)
    end
  end
end

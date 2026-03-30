# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/uptime'

RSpec.describe OsCtl::Lib::Uptime do
  it 'parses uptime and derives the boot time from Time.now' do
    with_tmpdir do |dir|
      path = File.join(dir, 'uptime')
      File.write(path, "120.5 456.75\n")

      now = Time.at(1_000)
      allow(Time).to receive(:now).and_return(now)

      uptime = described_class.new(path:)

      expect(uptime.uptime).to eq(120.5)
      expect(uptime.idle_time).to eq(456.75)
      expect(uptime.booted_at.to_f).to be_within(0.001).of(now.to_f - 120.5)
    end
  end
end

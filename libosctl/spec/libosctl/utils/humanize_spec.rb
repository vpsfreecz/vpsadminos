# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/utils/humanize'

RSpec.describe OsCtl::Lib::Utils::Humanize do
  let(:helper_class) do
    Class.new do
      include OsCtl::Lib::Utils::Humanize
    end
  end

  let(:helper) { helper_class.new }

  it 'formats data sizes, numbers, durations, and percentages' do
    expect(helper.humanize_data(1536)).to eq('1.5K')
    expect(helper.humanize_number(1500)).to eq('1.5K')
    expect(helper.humanize_time_us(2_000_000)).to eq('2s')
    expect(helper.humanize_time_ns(3_000_000_000)).to eq('3s')
    expect(helper.format_long_duration(90_061)).to eq('1 days, 01:01:01')
    expect(helper.format_short_duration(3661)).to eq('01:01:01')
    expect(helper.format_percent(12.34)).to eq(12.3)
    expect(helper.humanize_percent(12.34)).to eq('12.3%')
  end

  it 'parses plain integers, binary suffixes, and unknown formats' do
    expect(helper.parse_data('10')).to eq(10)
    expect(helper.parse_data('1G')).to eq(1_073_741_824)
    expect(helper.parse_data('bogus')).to eq('bogus')
  end
end

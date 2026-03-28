# frozen_string_literal: true

require 'osctld/system_limits'

RSpec.describe OsCtld::SystemLimits do
  subject(:limits) do
    described_class.send(:allocate).tap do |instance|
      instance.send(:init_lock)
      instance.instance_variable_set('@values', {})
    end
  end

  before do
    OsCtl::Lib::Logger.setup(:none)
  end

  it 'reads once, raises the limit when needed, and never lowers it' do
    allow(File).to receive(:read).with(described_class::FILE_MAX_PATH).and_return("100\n")
    allow(File).to receive(:write)

    limits.ensure_nofile(200)
    limits.ensure_nofile(150)
    limits.ensure_nofile(50)

    expect(File).to have_received(:read).once
    expect(File).to have_received(:write).with(described_class::FILE_MAX_PATH, '200').once
  end
end

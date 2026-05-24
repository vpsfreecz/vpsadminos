# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Main do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'uses the json exporter when --json is enabled' do
    model = instance_double(OsCtl::Cli::Top::Model, setup: nil)
    exporter = instance_double(OsCtl::Cli::Top::JsonExporter, start: nil)
    allow(OsCtl::Cli::Top::Model).to receive(:new).and_return(model)
    allow(OsCtl::Cli::Top::JsonExporter).to receive(:new).with(model, 2).and_return(exporter)

    cmd(opts: { iostat: true, rate: 2 }, gopts: { json: true }).start

    expect(exporter).to have_received(:start)
  end

  it 'uses the tui when json is disabled and forwards process mode' do
    model = instance_double(OsCtl::Cli::Top::Model, setup: nil)
    tui = instance_double(OsCtl::Cli::Top::Tui, start: nil)
    allow(OsCtl::Cli::Top::Model).to receive(:new).and_return(model)
    allow(OsCtl::Cli::Top::Tui).to receive(:new).with(model, 2, enable_procs: false).and_return(tui)

    cmd(opts: { iostat: true, rate: 2, processes: false }).start

    expect(tui).to have_received(:start)
  end

  it 'rejects zero refresh rate' do
    expect do
      cmd(opts: { iostat: true, rate: 0, processes: false }).start
    end.to raise_error(GLI::BadCommandLine, 'rate must be a positive finite number')
  end

  it 'rejects infinite refresh rate' do
    expect do
      cmd(opts: { iostat: true, rate: Float::INFINITY, processes: false }).start
    end.to raise_error(GLI::BadCommandLine, 'rate must be a positive finite number')
  end
end

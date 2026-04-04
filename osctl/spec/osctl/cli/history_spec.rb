# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::History do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  let(:history_rows) do
    [
      { time: 10, pool: 'tank', cmd: 'ct_start', opts: { cli: 'osctl ct start ct1' } },
      { time: 20, pool: 'pond', cmd: 'ct_stop', opts: {} }
    ]
  end

  it 'prints json output once for the full payload' do
    command = cmd(args: %w[tank pond], gopts: { json: true })
    allow(command).to receive(:osctld_call).and_return(history_rows)

    out, err = capture_output { command.list }

    expect(err).to eq('')
    expect(out.lines.size).to eq(1)
    expect(JSON.parse(out)).to eq(JSON.parse(history_rows.to_json))
    expect(command).to have_received(:osctld_call).with(:history_list, pools: %w[tank pond])
  end

  it 'formats text output in columns' do
    command = cmd
    allow(command).to receive(:osctld_call).and_return(history_rows)
    allow(OsCtl::Lib::Cli::OutputFormatter).to receive(:print)

    command.list

    expect(OsCtl::Lib::Cli::OutputFormatter).to have_received(:print).with(
      history_rows,
      cols: kind_of(Array),
      layout: :columns
    )
  end
end

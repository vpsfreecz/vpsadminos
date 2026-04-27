# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::TransferProgress do
  def cmd(gopts: {})
    build_command(OsCtl::Cli::Send, gopts:)
  end

  it 'renders terminal and json progress updates' do
    command = cmd(gopts: { json: false })
    progress_bar = double(
      'progress_bar',
      total: 10,
      'total=': nil,
      'format=': nil,
      'progress=': nil,
      finish: nil,
      cancel: nil
    )
    allow(ProgressBar).to receive(:create).and_return(progress_bar)

    out, = capture_output do
      command.send(:terminal_progress, 'working')
      command.send(:terminal_progress, type: :step, title: 'Snapshot')
      command.send(:terminal_progress, type: :progress, data: { size: 10, transfered: 5 })
    end

    expect(out).to include('> working', '* Snapshot')
    expect(progress_bar).to have_received(:progress=).with(5)

    json_command = cmd(gopts: { json: true })
    out, = capture_output do
      json_command.send(:json_progress, 'working')
      json_command.send(:json_progress, type: :step, title: 'Snapshot')
      json_command.send(:json_progress, type: :progress, data: { size: 10 })
    end
    expect(out.lines.map { |line| JSON.parse(line) }).to include(
      { 'type' => 'update', 'text' => 'working' },
      { 'type' => 'step', 'text' => 'Snapshot' },
      { 'type' => 'progress', 'data' => { 'size' => 10 } }
    )
  end

  it 'finishes or cancels the progress bar around with_progress' do
    progress_bar = double('progress_bar', finish: nil, cancel: nil)
    command = cmd
    command.instance_variable_set(:@pb, progress_bar)

    allow(command).to receive(:osctld_call).and_return('ok')
    command.send(:with_progress, :ct_send_sync, id: 'ct1')
    expect(progress_bar).to have_received(:finish)

    command.instance_variable_set(:@pb, progress_bar)
    allow(command).to receive(:osctld_call).and_raise(OsCtl::Client::Error, 'boom')
    expect do
      command.send(:with_progress, :ct_send_sync, id: 'ct1')
    end.to raise_error(OsCtl::Client::Error, 'boom')
    expect(progress_bar).to have_received(:cancel)
  end
end

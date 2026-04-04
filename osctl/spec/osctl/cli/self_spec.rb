# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Self do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'prints healthcheck data in json and text modes' do
    json_command = cmd(opts: { all: false }, gopts: { json: true })
    allow(json_command).to receive(:osctld_call).and_return([{ type: 'pool', pool: 'tank', id: nil, assets: [] }])
    out, = capture_output { json_command.healthcheck }
    expect(JSON.parse(out)).to eq([{ 'type' => 'pool', 'pool' => 'tank', 'id' => nil, 'assets' => [] }])

    text_command = cmd
    allow(text_command).to receive(:osctld_call).and_return([])
    out, = capture_output { text_command.healthcheck }
    expect(out).to eq("No errors detected.\n")
  end

  it 'retries ping for a bounded interval and prints pong on success' do
    command = cmd(args: ['2'])
    attempts = 0
    allow(command).to receive(:do_ping) do
      attempts += 1
      raise GLI::CustomExit.new('nope', 1) if attempts < 3

      true
    end
    allow(command).to receive(:sleep)

    command.ping

    expect(command).to have_received(:sleep).twice
  end

  it 'activates and aborts shutdown through osctld' do
    activate = cmd(opts: { system: true })
    aborting = cmd(opts: { abort: true })

    expect(activate).to receive(:osctld_fmt).with(:self_activate, cmd_opts: { system: true })
    activate.activate

    expect(aborting).to receive(:osctld_fmt).with(:self_abort_shutdown)
    aborting.shutdown
  end

  it 'aborts shutdown when confirmation is rejected' do
    command = cmd

    out, = capture_output do
      with_stdin("n\n") { command.shutdown }
    end

    expect(out).to include('Do you really wish', 'Aborting')
  end

  it 'waits for the shutdown marker when osctld disconnects' do
    marker = '/tmp/osctl-shutdown-marker'
    stub_const("#{described_class}::SHUTDOWN_MARKER", marker)
    command = cmd(opts: { force: true, wall: true, message: 'bye' })
    allow(File).to receive(:new).with(marker, 'w', 0o000).and_return(double(close: nil))
    allow(command).to receive(:osctld_fmt).and_raise(OsCtl::Client::Error, 'lost')
    allow(File).to receive(:stat).with(marker).and_return(double(mode: 0o100))
    allow(command).to receive(:sleep)

    out, err = capture_output { command.shutdown }

    expect(out).to include('Waiting for osctld to prepare for shutdown...')
    expect(err).to include('Lost connection to osctld: lost', ' ok')
  end

  it 'loads scripts from disk and reports missing scripts' do
    with_tempdir do |dir|
      path = File.join(dir, 'script.rb')
      marker = File.join(dir, 'loaded.txt')
      File.write(path, "File.write(#{marker.inspect}, 'loaded')\n")
      script = cmd(args: [path])

      with_argv(['script', path]) do
        script.script
      end

      expect(File.read(marker)).to eq('loaded')
    end

    missing = cmd(args: ['/tmp/missing.rb'])
    allow(File).to receive(:realpath).and_raise(Errno::ENOENT)
    allow(missing).to receive(:exit).and_raise(SystemExit.new(false))
    out, err = capture_output do
      expect do
        with_argv(%w[script /tmp/missing.rb]) { missing.script }
      end.to raise_error(SystemExit)
    end
    expect(out).to eq('')
    expect(err).to include('Script not found')
  end
end

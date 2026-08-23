# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Daemon do
  def cmd(opts: {}, gopts: {})
    build_command(described_class, opts:, gopts:)
  end

  it 'prints structured status returned by a generation-aware daemon' do
    command = cmd(gopts: { json: true })
    allow(command).to receive(:osctld_call).with(:daemon_status).and_return(
      schema: 1,
      legacy: false,
      initialized: true,
      phase: 'ready',
      ready: true,
      lifecycle_admission: true
    )

    output, = capture_output { command.status }

    expect(JSON.parse(output)).to include(
      'schema' => 1,
      'legacy' => false,
      'phase' => 'ready',
      'ready' => true
    )
  end

  it 'detects a legacy daemon through the existing self status command' do
    command = cmd(gopts: { json: true })
    allow(command).to receive(:osctld_call).with(:daemon_status).and_raise(
      OsCtl::Client::Error,
      "Unsupported command 'daemon_status'"
    )
    allow(command).to receive(:osctld_call).with(:self_status).and_return(
      started_at: 123,
      initialized: true
    )

    output, = capture_output { command.status }

    expect(JSON.parse(output)).to include(
      'schema' => 0,
      'legacy' => true,
      'phase' => 'ready',
      'ready' => true
    )
  end

  it 'passes lifecycle control commands and readiness timeout to osctld' do
    prepare = cmd
    resume = cmd
    wait = cmd(opts: { timeout: 42 })

    expect(prepare).to receive(:osctld_fmt).with(:daemon_prepare_stop)
    expect(resume).to receive(:osctld_fmt).with(:daemon_resume)
    expect(wait).to receive(:osctld_fmt).with(
      :daemon_wait_ready,
      cmd_opts: { timeout: 42 }
    )

    prepare.prepare_stop
    resume.resume
    wait.wait_ready
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Container do
  let(:command) { build_command(described_class) }
  let(:client) do
    instance_double(
      FakeClientHelpers::ClientDouble,
      socket: response_pipe.first,
      receive_resp: client_response(status: true, response: { exitstatus: 0 })
    )
  end
  let(:response_pipe) { IO.pipe }
  let(:input_pipe) { IO.pipe }
  let(:remote_ios) { [] }

  around do |example|
    original_stdin = $stdin
    $stdin = input_pipe.first
    example.run
  ensure
    $stdin = original_stdin
    (input_pipe + response_pipe + remote_ios).each do |io|
      io.close unless io.closed?
    end
  end

  def prepare_command(stdout: '', stderr: '', close_outputs: true, close_input: false)
    allow(client).to receive(:send_io) do |io|
      remote_ios << io.dup
      next unless remote_ios.length == 3

      remote_ios[1].write(stdout)
      remote_ios[2].write(stderr)
      remote_ios[0].close if close_input
      remote_ios[1..].each(&:close) if close_outputs
      response_pipe.last.write('ready')
    end
  end

  def first_ready(io)
    first = true
    allow(IO).to receive(:select).and_wrap_original do |original, watched, *args|
      if first
        first = false
        [[io == :stdout ? watched[1] : io], [], []]
      else
        original.call(watched, *args)
      end
    end
  end

  it 'does not lose stderr when stdout reaches EOF first' do
    prepare_command(stderr: "Operation not permitted\n")
    first_ready(:stdout)

    out, err = capture_output { command.send(:handle_exec_io, client) }

    expect(out).to eq('')
    expect(err).to eq("Operation not permitted\n")
    expect(client).to have_received(:receive_resp).once
  end

  it 'drains more than one buffer from each stream before handling completion' do
    stdout = "#{'o' * 5000}\nstdout tail\n"
    stderr = "#{'e' * 5000}\nstderr tail\n"
    prepare_command(stdout:, stderr:)
    first_ready(response_pipe.first)

    out, err = capture_output { command.send(:handle_exec_io, client) }

    expect(out).to eq(stdout)
    expect(err).to eq(stderr)
  end

  it 'does not wait for inherited writers after command completion' do
    prepare_command(stdout: 'stdout', stderr: 'stderr', close_outputs: false)
    first_ready(response_pipe.first)

    out, err = capture_output { command.send(:handle_exec_io, client) }

    expect(out).to eq('stdout')
    expect(err).to eq('stderr')
  end

  it 'does not follow output written by descendants after the completion snapshot' do
    prepare_command(stdout: 'command output', close_outputs: false)
    first_ready(response_pipe.first)

    out, = capture_output do
      injected = false
      allow($stdout).to receive(:write).and_wrap_original do |original, data|
        unless injected
          remote_ios[1].write('later descendant output')
          injected = true
        end

        original.call(data)
      end

      command.send(:handle_exec_io, client)
    end

    expect(out).to eq('command output')
  end

  it 'preserves diagnostics and exit status when the command closes stdin' do
    prepare_command(stderr: "command failed\n", close_input: true)
    input_pipe.last.write('input')
    first_ready(input_pipe.first)
    allow(client).to receive(:receive_resp).and_return(
      client_response(status: true, response: { exitstatus: 7 })
    )

    out, err = capture_output do
      expect { command.send(:handle_exec_io, client) }.to raise_error(GLI::CustomExit) { |e|
        expect(e.exit_code).to eq(7)
      }
    end

    expect(out).to eq('')
    expect(err).to eq("command failed\n")
  end

  it 'continues reading output after local stdin reaches EOF' do
    prepare_command(stdout: 'stdout', stderr: 'stderr')
    input_pipe.last.close
    first_ready(input_pipe.first)

    out, err = capture_output { command.send(:handle_exec_io, client) }

    expect(out).to eq('stdout')
    expect(err).to eq('stderr')
    expect(input_pipe.first).not_to be_closed
    expect(response_pipe.first).not_to be_closed
  end

  it 'closes every local pipe endpoint on a daemon error' do
    prepare_command(stderr: 'diagnostic')
    first_ready(response_pipe.first)
    allow(client).to receive(:receive_resp).and_return(client_response(status: false, message: 'daemon error'))
    local_pipes = []
    allow(IO).to receive(:pipe).and_wrap_original do |original|
      original.call.tap { |pair| local_pipes.concat(pair) }
    end

    _out, err = capture_output do
      expect { command.send(:handle_exec_io, client) }.to raise_error('daemon error')
    end

    expect(err).to eq('diagnostic')
    expect(local_pipes.length).to eq(6)
    expect(local_pipes).to all(be_closed)
  end
end

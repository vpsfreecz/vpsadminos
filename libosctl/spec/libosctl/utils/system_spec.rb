# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/exceptions'
require 'libosctl/logger'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'

RSpec.describe OsCtl::Lib::Utils::System do
  let(:helper_class) do
    Class.new do
      include OsCtl::Lib::Utils::Log
      include OsCtl::Lib::Utils::System
    end
  end

  let(:helper) { helper_class.new }

  before do
    allow(OsCtl::Lib::Logger).to receive(:log)
  end

  it 'runs commands successfully and returns their output' do
    result = helper.syscmd(%q(ruby -e 'STDOUT.write "ok"'))

    expect(result).to be_success
    expect(result.output).to eq('ok')
  end

  it 'raises on non-zero exit status unless the status is valid' do
    expect do
      helper.syscmd(%q(ruby -e 'STDERR.write "boom"; exit 5'))
    end.to raise_error(OsCtl::Lib::Exceptions::SystemCommandFailed, /exited with code '5'/)

    result = helper.syscmd("ruby -e 'exit 4'", valid_rcs: [4])

    expect(result.exitstatus).to eq(4)
  end

  it 'supports stderr suppression, stdin input, and environment variables' do
    stdout_only = helper.syscmd(
      "ruby -e 'STDOUT.write \"out\"; STDERR.write \"err\"'",
      stderr: false
    )

    expect(stdout_only.output).to eq('out')

    env_and_input = helper.syscmd(
      "ruby -e 'print [ENV.fetch(\"FOO\"), STDIN.read].join(\"::\")'",
      env: { 'FOO' => 'env' },
      input: 'payload'
    )

    expect(env_and_input.output).to eq('env::payload')
  end

  it 'handles timeouts with and without an on_timeout callback' do
    expect do
      helper.syscmd("ruby -e 'sleep 5'", timeout: 0.1)
    end.to raise_error(OsCtl::Lib::Exceptions::SystemCommandFailed)

    called = false

    expect do
      helper.syscmd(
        "ruby -e 'sleep 5'",
        timeout: 0.1,
        on_timeout: lambda { |io|
          called = true
          Process.kill('KILL', io.pid)
        }
      )
    end.to raise_error(OsCtl::Lib::Exceptions::SystemCommandFailed)

    expect(called).to be(true)
  end

  it 'builds zfs commands through syscmd' do
    allow(helper).to receive(:syscmd).and_return(command_result(output: "tank\n"))

    helper.zfs(:list, '-H', 'tank', stderr: false)

    expect(helper).to have_received(:syscmd).with('zfs list -H tank', { stderr: false })
  end

  it 'retries system command failures until success or exhaustion' do
    allow(helper).to receive(:sleep)
    attempts = 0

    success = helper.repeat_on_failure(attempts: 3, wait: 0) do
      attempts += 1
      raise OsCtl::Lib::Exceptions::SystemCommandFailed.new('cmd', 1, '') if attempts < 2

      :ok
    end

    expect(success).to eq([true, :ok])

    failures = helper.repeat_on_failure(attempts: 2, wait: 0) do
      raise OsCtl::Lib::Exceptions::SystemCommandFailed.new('cmd', 1, '')
    end

    expect(failures.first).to be(false)
    expect(failures.last.length).to eq(2)
  end

  it 'does not swallow non-SystemCommandFailed exceptions' do
    expect do
      helper.repeat_on_failure(attempts: 2, wait: 0) do
        raise ArgumentError, 'boom'
      end
    end.to raise_error(ArgumentError, 'boom')
  end
end

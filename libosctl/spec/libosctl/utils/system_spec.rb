# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/exceptions'
require 'libosctl/logger'
require 'libosctl/system_command_result'
require 'libosctl/utils/log'
require 'libosctl/utils/system'
require 'rbconfig'

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

  describe '#syscmd_argv' do
    it 'runs commands without a shell' do
      result = helper.syscmd_argv(
        [
          RbConfig.ruby,
          '-e',
          'STDOUT.write [ARGV.fetch(0), ARGV.fetch(1)].join("\n")',
          'value with spaces',
          'literal *'
        ]
      )

      expect(result).to be_success
      expect(result.output).to eq("value with spaces\nliteral *")
    end

    it 'raises on non-zero exit status unless the status is valid' do
      expect do
        helper.syscmd_argv([RbConfig.ruby, '-e', 'STDERR.write "boom"; exit 5'])
      end.to raise_error(OsCtl::Lib::Exceptions::SystemCommandFailed, /exited with code '5'/)

      result = helper.syscmd_argv([RbConfig.ruby, '-e', 'exit 4'], valid_rcs: [4])

      expect(result.exitstatus).to eq(4)
    end

    it 'supports stderr suppression, stdin input, and environment variables' do
      stdout_only = helper.syscmd_argv(
        [RbConfig.ruby, '-e', 'STDOUT.write "out"; STDERR.write "err"'],
        stderr: false
      )

      expect(stdout_only.output).to eq('out')

      env_and_input = helper.syscmd_argv(
        [RbConfig.ruby, '-e', 'print [ENV.fetch("FOO"), STDIN.read].join("::")'],
        env: { 'FOO' => 'env' },
        input: 'payload'
      )

      expect(env_and_input.output).to eq('env::payload')
    end
  end

  describe 'absolute command deadlines' do
    def command_deadline(seconds = 2)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    end

    it 'preserves command arguments, environment, input and valid exit codes' do
      result = helper.syscmd_argv(
        [RbConfig.ruby, '-e', 'print [ENV.fetch("VALUE"), ARGV.first, STDIN.read].join(":"); exit 3', 'literal *'],
        deadline: command_deadline,
        env: { 'VALUE' => 'env' }, input: 'data', valid_rcs: [3]
      )
      expect(result.output).to eq('env:literal *:data')
      expect(result.exitstatus).to eq(3)
      expect(helper.syscmd('echo shell', deadline: command_deadline).output).to eq("shell\n")
    end

    it 'moves input and output concurrently without blocking on full pipes' do
      payload = 'x' * 262_144
      result = helper.syscmd_argv(
        [RbConfig.ruby, '-e', 'STDOUT.write("y" * 262144); print STDIN.read.length'],
        deadline: command_deadline, input: payload
      )
      expect(result.output).to eq(('y' * 262_144) + payload.length.to_s)
    end

    it 'suppresses stderr and reports command failure' do
      result = helper.syscmd_argv(
        [RbConfig.ruby, '-e', 'STDOUT.write("out"); STDERR.write("err")'],
        deadline: command_deadline, stderr: false
      )
      expect(result.output).to eq('out')
      expect { helper.syscmd('exit 3', deadline: command_deadline) }
        .to raise_error(OsCtl::Lib::Exceptions::SystemCommandFailed)
    end

    ['sleep 60', 'STDOUT.close; sleep 60'].each do |script|
      it "bounds command output and exit waiting for #{script}" do
        reapers = []
        allow(Process).to receive(:detach).and_wrap_original do |original, pid|
          original.call(pid).tap { |reaper| reapers << reaper }
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect do
          helper.syscmd_argv([RbConfig.ruby, '-e', script], deadline: command_deadline(0.1))
        end.to raise_error(OsCtl::Lib::Exceptions::SystemCommandTimeout)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
        expect(reapers.length).to eq(1)
        expect(reapers.first.join(2)).not_to be_nil
        expect(reapers.first.value.termsig).to eq(Signal.list.fetch('KILL'))
      end
    end

    it 'bounds a command that never reads its input' do
      expect do
        helper.syscmd_argv(
          [RbConfig.ruby, '-e', 'sleep 60'], deadline: command_deadline(0.1), input: 'x' * 262_144
        )
      end.to raise_error(OsCtl::Lib::Exceptions::SystemCommandTimeout)
    end

    it 'does not start a command after the deadline' do
      allow(Process).to receive(:spawn)
      expect { helper.syscmd('true', deadline: command_deadline(-1)) }
        .to raise_error(OsCtl::Lib::Exceptions::SystemCommandTimeout)
      expect(Process).not_to have_received(:spawn)
    end
  end

  describe '#find_executable!' do
    it 'resolves executables to real paths' do
      with_tmpdir do |tmpdir|
        store_bin = File.join(tmpdir, 'nix/store/fake-package/bin')
        path_bin = File.join(tmpdir, 'profile/bin')
        executable = File.join(store_bin, 'tool')

        FileUtils.mkdir_p(store_bin)
        FileUtils.mkdir_p(path_bin)
        File.write(executable, "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, executable)
        File.symlink(executable, File.join(path_bin, 'tool'))

        old_path = ENV.fetch('PATH', nil)

        begin
          ENV['PATH'] = path_bin

          expect(helper.find_executable!('tool')).to eq(executable)
        ensure
          ENV['PATH'] = old_path
        end
      end
    end

    it 'raises when the executable is absent' do
      old_path = ENV.fetch('PATH', nil)

      begin
        ENV['PATH'] = ''

        expect { helper.find_executable!('missing') }.to raise_error(Errno::ENOENT)
      ensure
        ENV['PATH'] = old_path
      end
    end
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

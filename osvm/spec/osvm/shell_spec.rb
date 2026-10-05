# frozen_string_literal: true

require 'spec_helper'
require 'io/wait'

RSpec.describe OsVm::Shell do
  def build_shell(
    dir:,
    machine: instance_double(OsVm::Machine, name: 'test', running?: true, raise_if_kernel_failed!: nil)
  )
    described_class.new(
      machine,
      0,
      File.join(dir, 'shell.sock'),
      File.join(dir, 'shell.log'),
      default_timeout: 10
    )
  end

  def with_command_shell
    with_tmpdir do |dir|
      shell = build_shell(dir:)

      IO.popen(%w[bash --noprofile --norc], 'r+') do |io|
        io.sync = true
        shell.instance_variable_set(:@io, io)
        shell.instance_variable_set(:@up, true)
        yield shell, io
      end
    ensure
      shell&.finalize
    end
  end

  it 'does not attribute a late response from a timed-out command to the next command' do
    with_command_shell do |shell, io|
      io.write("printf '#{Base64.strict_encode64('late reply')}\\n0\\n'\n")

      expect(shell.execute('printf current')).to eq([0, 'current'])
      expect(shell.execute('printf next; exit 37')).to eq([37, 'next'])
    end
  end

  it 'preserves binary output and empty output with the matching exit status' do
    with_command_shell do |shell, _io|
      expect(shell.execute("printf 'line\\n\\000\\377tail'; exit 17")).to eq(
        [17, "line\n\x00\xfftail".b]
      )
      expect(shell.execute('true')).to eq([0, ''])
    end
  end

  it 'does not prepend an unfinished stale payload to the current wrapped reply' do
    with_command_shell do |shell, io|
      io.write("printf '#{Base64.strict_encode64('unfinished stale reply')}'\n")

      expect(shell.execute('printf current; exit 23')).to eq([23, 'current'])
    end
  end

  it 'preserves timeout statuses from commands which complete within the shell deadline' do
    with_command_shell do |shell, _io|
      expect(shell.execute('printf completed; exit 124')).to eq([124, 'completed'])
      expect(shell.execute('printf completed; exit 137')).to eq([137, 'completed'])
      expect(shell.execute('timeout 0.1 sleep 2')).to eq([124, ''])
      expect(shell.execute('printf after; exit 125')).to eq([125, 'after'])
    end
  end

  it 'reads a framed response larger than an IO read buffer' do
    with_command_shell do |shell, _io|
      payload = '0123456789' * 2000

      expect(shell.execute("printf '#{payload}'")).to eq([0, payload])
    end
  end

  it 'preserves a large reply, its exit status, and the following reply' do
    with_command_shell do |shell, _io|
      expect(shell.execute("head -c 1048576 /dev/zero | tr '\\0' x; exit 37")).to eq([37, 'x' * 1_048_576])
      expect(shell.execute('printf after; exit 11')).to eq([11, 'after'])
    end
  end

  it 'ignores stale framed records without renewing the response deadline' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:monotonic_now).and_return(100, 101, 103)
      allow(shell).to receive(:read_output).and_return(
        "bGF0ZQ==:old-marker:0\n",
        ":other-marker:begin\nc3RhbGU=\n:other-marker:0\n" \
        ":current-marker:begin\nY3VycmVudA==\n:current-marker:27\n"
      )

      expect(shell.send(:read_command_result, 'current-marker', timeout: 5, command: 'test')).to eq(
        [27, 'current']
      )
      expect(shell).to have_received(:read_output).with(
        timeout: 4, deadline: 105, timeout_message: "Timeout occurred while running command 'test'",
        command: 'test', trace: nil
      )
      expect(shell).to have_received(:read_output).with(
        timeout: 2, deadline: 105, timeout_message: "Timeout occurred while running command 'test'",
        command: 'test', trace: nil
      )
    ensure
      shell&.finalize
    end
  end

  it 'rejects malformed matching payloads and resets the stream' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:read_output).and_return(":current:begin\nA===\n:current:0\n")
      allow(shell).to receive(:reset).and_call_original

      expect do
        shell.send(:read_command_result, 'current', timeout: 5, command: 'test')
      end.to raise_error(ArgumentError)
      expect(shell).to have_received(:reset)
    ensure
      shell&.finalize
    end
  end

  it 'keeps ordinary command timeouts and can execute the following command' do
    with_command_shell do |shell, _io|
      expect do
        shell.execute('printf partial; sleep 10', timeout: 5)
      end.to raise_error(OsVm::TimeoutError, /output: "partial"/)

      expect(shell.execute('printf after')).to eq([0, 'after'])
    end
  end

  it 'builds serial-port options from its index and socket path' do
    with_tmpdir do |dir|
      shell = described_class.new(
        instance_double(OsVm::Machine),
        2,
        File.join(dir, 'shell2.sock'),
        File.join(dir, 'shell2.log'),
        default_timeout: 10,
        transport: 'virtserialport'
      )

      expect(shell.chardev_id).to eq('shell2')
      expect(shell.qemu_options).to eq(
        [
          '-chardev', "socket,id=shell2,path=#{File.join(dir, 'shell2.sock')}",
          '-device', 'virtserialport,chardev=shell2,name=org.osvm.shell2'
        ]
      )
    end
  end

  it 'resets and raises when shell output hits eof' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      io = instance_double(IO, wait_readable: true, closed?: false, close: nil)
      shell.instance_variable_set(:@io, io)
      shell.instance_variable_set(:@up, true)
      allow(shell).to receive(:read_nonblock).and_raise(EOFError)

      expect do
        shell.send(:read_output, timeout: 1, command: 'echo test')
      end.to raise_error(OsVm::MachineShellClosed)

      expect(shell.instance_variable_get(:@io)).to be_nil
      expect(shell).not_to be_up
    end
  end

  it 'reads wrapped output through the protocol terminator' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      io = instance_double(IO, wait_readable: true, closed?: false, close: nil)
      shell.instance_variable_set(:@io, io)
      shell.instance_variable_set(:@up, true)
      encoded = Base64.strict_encode64('firstsecond')
      allow(shell).to receive(:read_nonblock).and_return(
        "#{encoded[0, 8]}\n",
        "#{encoded[8..]}\n",
        "#{described_class::OUTPUT_END_MARKER}\n"
      )

      output = shell.send(
        :read_output,
        timeout: 1,
        command: 'printf output',
        terminator: "#{described_class::OUTPUT_END_MARKER}\n"
      )

      expect(Base64.decode64(output)).to eq('firstsecond')
      expect(shell).to have_received(:read_nonblock).exactly(3).times
    end
  end

  it 'does not restart a stopped machine after a detected kernel failure' do
    with_tmpdir do |dir|
      failure = OsVm::KernelFailure.new(
        machine_name: 'test',
        console_line: 'Oops: test failure',
        console_log_path: File.join(dir, 'console.log')
      )
      machine = instance_double(OsVm::Machine, running?: false, start: nil, name: 'test')
      allow(machine).to receive(:raise_if_kernel_failed!).and_raise(failure)
      shell = build_shell(dir:, machine:)

      expect { shell.execute('true') }.to raise_error(failure)
      expect(machine).not_to have_received(:start)
    end
  end

  it 'reserves forced-kill and protocol-drain time for guest commands' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      writes = []
      io = instance_double(IO)
      allow(io).to receive(:write) { |data| writes << data }
      allow(SecureRandom).to receive(:hex).with(16).and_return('test-marker')
      allow(shell).to receive_messages(
        monotonic_now: 100.0,
        read_output: ":osvm-test-marker:begin\n#{Base64.strict_encode64("ok\n:osvm-test-marker-completed:0")}\n:osvm-test-marker:0\n"
      )
      shell.instance_variable_set(:@io, io)

      expect(shell.send(:execute_command, 'true', timeout: 10)).to eq([0, "ok\n"])
      expect(writes.first).to include('timeout --kill-after=1 7 bash')
      expect(writes.first).to include(
        'base64 -w 76;', ':osvm-test-marker:begin', ':osvm-test-marker:%s'
      )
    end
  end

  it 'checks successful and failed commands' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)

      allow(shell).to receive(:execute).with('true', timeout: 10).and_return([0, "ok\n"])
      allow(shell).to receive(:execute).with('false', timeout: 10).and_return([1, "fail\n"])

      expect(shell.succeeds('true')).to eq([0, "ok\n"])
      expect(shell.fails('false')).to eq([1, "fail\n"])
    end
  end

  it 'retains the original protocol timeout when reset raises another timeout' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      io = instance_double(IO, write: 1, wait_readable: true, closed?: false)
      shell.instance_variable_set(:@io, io)
      shell.instance_variable_set(:@up, true)
      reads = 0
      allow(shell).to receive(:read_nonblock) do
        reads += 1
        raise OsVm::UnrecoverableTimeoutError, 'original output deadline' if reads > 1

        'cGFydGlhbA=='
      end
      allow(io).to receive(:close).and_raise(OsVm::TimeoutError, 'reset interrupted')

      expect do
        shell.execute('poweroff -f', timeout: 1)
      end.to raise_error(OsVm::TimeoutError, 'reset interrupted')

      log = File.read(File.join(dir, 'shell.log'))
      expect(log).to include('PHASE: output_read')
      expect(log).to include('PROTOCOL_ERROR: OsVm::UnrecoverableTimeoutError: original output deadline')
      expect(log).to include('ERROR: OsVm::TimeoutError: reset interrupted')
      expect(log).to include('REPLY_BUFFER_BYTES: 12')
      expect(log).to include('REPLY_BUFFER_PREFIX: "cGFydGlhbA=="')
      expect(shell.instance_variable_get(:@io)).to be_nil
      expect(shell).not_to be_up
    end
  end

  it 'retains the framed-result read phase without changing an unrecoverable timeout' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      io = instance_double(IO, write: 1, wait_readable: true, closed?: false, close: nil)
      allow(SecureRandom).to receive(:hex).with(16).and_return('test-marker')
      shell.instance_variable_set(:@io, io)
      shell.instance_variable_set(:@up, true)
      reads = 0
      allow(shell).to receive(:read_nonblock) do
        reads += 1
        raise OsVm::UnrecoverableTimeoutError, 'original status deadline' if reads > 1

        ":osvm-test-marker:begin\n#{Base64.strict_encode64("ok\n:osvm-test-marker-completed:0")}\n"
      end

      expect do
        shell.execute('true', timeout: 1)
      end.to raise_error(OsVm::UnrecoverableTimeoutError, 'original status deadline')

      log = File.read(File.join(dir, 'shell.log'))
      expect(log).to include('PHASE: output_read')
      expect(log).to include('ERROR: OsVm::UnrecoverableTimeoutError: original status deadline')
      expect(log).to include('REPLY_BUFFER_BYTES: 0')
      expect(shell.instance_variable_get(:@io)).to be_nil
      expect(shell).not_to be_up
    end
  end

  it 'keeps successful protocol replies unchanged without additional timeout logging' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      io = instance_double(IO, write: 1, wait_readable: true)
      allow(SecureRandom).to receive(:hex).with(16).and_return('test-marker')
      shell.instance_variable_set(:@io, io)
      shell.instance_variable_set(:@up, true)
      allow(shell).to receive(:read_nonblock).and_return(
        ":osvm-test-marker:begin\n#{Base64.strict_encode64("ok\n:osvm-test-marker-completed:0")}\n:osvm-test-marker:0\n"
      )

      expect(shell.execute('true', timeout: 1)).to eq([0, "ok\n"])
      expect(io).to have_received(:write).once
      log = File.read(File.join(dir, 'shell.log'))
      expect(log).to include('STATUS: 0')
      expect(log).not_to include('ACTION: protocol-timeout')
    end
  end

  it 'bounds the additional protocol timeout record' do
    with_tmpdir do |dir|
      path = File.join(dir, 'shell.log')
      log = OsVm::ShellLog.new(path)
      trace = { phase: 'output_read', reply_buffer: 'x' * 40_000, protocol_error: 'y' * 10_000 }
      log.execute_timeout(OsVm::TimeoutError.new('z' * 10_000), trace)
      log.close
      text = File.read(path)

      expect(text).to include('REPLY_BUFFER_BYTES: 40000')
      expect(text).to include("REPLY_BUFFER_PREFIX: #{('x' * 32_768).inspect}")
      expect(text).not_to include('x' * 32_769)
      expect(text).not_to include('y' * 4097)
      expect(text).not_to include('z' * 4097)
    end
  end

  it 'raises when success expectations are not met' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)

      allow(shell).to receive(:execute).with('false', timeout: 10).and_return([1, "fail\n"])
      allow(shell).to receive(:execute).with('true', timeout: 10).and_return([0, "ok\n"])

      expect do
        shell.succeeds('false')
      end.to raise_error(OsVm::CommandFailed, /failed with status 1/)

      expect do
        shell.fails('true')
      end.to raise_error(OsVm::CommandSucceeded, /succeeds with status 0/)
    end
  end

  it 'retries successful command expectations a bounded number of times' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('flaky', timeout: 7)
        .and_return([1, 'first'], [2, 'second'], [0, 'ready'])

      expect(
        shell.succeeds_with_retries('flaky', attempts: 3, retry_delay: 2, timeout: 7)
      ).to eq([0, 'ready'])
      expect(shell).to have_received(:sleep).with(2).twice
    end
  end

  it 'raises the last failure after all command attempts are used' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('broken', timeout: 10)
        .and_return([1, 'first'], [3, 'last'])

      expect do
        shell.succeeds_with_retries('broken', attempts: 2)
      end.to raise_error(OsVm::CommandFailed, /status 3.*last/m)
      expect(shell).to have_received(:sleep).with(1).once
    end
  end

  it 'retries failed command expectations a bounded number of times' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('eventually-down', timeout: 8)
        .and_return([0, 'first'], [0, 'second'], [4, 'stopped'])

      expect(
        shell.fails_with_retries(
          'eventually-down', attempts: 3, retry_delay: 3, timeout: 8
        )
      ).to eq([4, 'stopped'])
      expect(shell).to have_received(:sleep).with(3).twice
    end
  end

  it 'raises the last success after all command attempts are used' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('still-running', timeout: 10)
        .and_return([0, 'first'], [0, 'last'])

      expect do
        shell.fails_with_retries('still-running', attempts: 2)
      end.to raise_error(OsVm::CommandSucceeded, /status 0.*last/m)
      expect(shell).to have_received(:sleep).with(1).once
    end
  end

  it 'requires at least one command attempt for both expectations' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)

      %i[succeeds_with_retries fails_with_retries].each do |method|
        [0, -1, 1.5].each do |attempts|
          expect do
            shell.public_send(method, 'never', attempts:)
          end.to raise_error(ArgumentError, /attempts must be a positive integer/)
        end
      end
    end
  end

  it 'waits until commands succeed or fail' do
    with_tmpdir do |dir|
      shell = build_shell(dir:)
      allow(shell).to receive(:sleep)
      allow(shell).to receive(:execute)
        .with('ready', timeout: anything)
        .and_return([1, 'not yet'], [0, 'ready'])
      allow(shell).to receive(:execute)
        .with('down', timeout: anything)
        .and_return([0, 'still up'], [1, 'down'])

      expect(shell.wait_until_succeeds('ready')).to eq([0, 'ready'])
      expect(shell.wait_until_fails('down')).to eq([1, 'down'])
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::Machine do
  describe '#kill' do
    it 'returns self when the machine is already stopped' do
      with_tmpdir do |dir|
        machine = build_machine(dir:)

        expect(machine.kill).to eq(machine)
      end
    end
  end

  describe '#kill_after_kernel_failure' do
    let(:clock) { [0.0] }

    before do
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.first }
    end

    def with_failed_machine
      with_tmpdir do |dir|
        machine = build_machine(dir:)
        allow(machine).to receive(:kill).and_return(machine)
        machine.send(:append_console_output, "[    1.000] Kernel panic - not syncing: test panic\n")
        yield machine
        expect(machine).to have_received(:kill).with(signal: 'KILL').once
      end
    end

    def on_console_wait(machine, &block)
      cv = machine.instance_variable_get(:@console_cv)

      allow(cv).to receive(:wait) do |mutex, timeout|
        # Simulate a condition-variable wakeup deterministically, including its
        # release/reacquisition of the mutex so console ingestion runs normally.
        mutex.unlock
        begin
          block.call(timeout)
        ensure
          mutex.lock
        end
      end
    end

    it 'kills without waiting when no kernel failure was detected' do
      with_tmpdir do |dir|
        machine = build_machine(dir:)
        cv = machine.instance_variable_get(:@console_cv)
        allow(cv).to receive(:wait) { raise 'unexpected console wait' }
        allow(machine).to receive(:kill).and_return(machine)

        expect(machine.kill_after_kernel_failure).to eq(machine)
        expect(cv).not_to have_received(:wait)
        expect(machine).to have_received(:kill).with(signal: 'KILL').once
      end
    end

    it 'retains delayed panic output until the console becomes quiet without clearing the failure' do
      with_failed_machine do |machine|
        wakeups = [15.0, 40.0, 70.0]
        chunks = ["Dumping ftrace buffer:\n", "late queue record\nend of dump\n", nil]
        waits = []

        on_console_wait(machine) do |timeout|
          waits << timeout
          clock[0] = wakeups.shift || raise('unexpected extra wait')
          chunk = chunks.shift
          machine.send(:append_console_output, chunk) if chunk
        end

        expect(machine.kill_after_kernel_failure).to eq(machine)
        expect(waits).to eq([30.0, 30.0, 30.0])
        expect(clock.first).to eq(70.0)
        expect(machine.console_output).to include("late queue record\nend of dump\n")
        expect { machine.raise_if_kernel_failed! }.to raise_error(OsVm::KernelFailure, /test panic/)
      end
    end

    it 'enforces the hard deadline even while new output keeps arriving' do
      with_failed_machine do |machine|
        wakeups = [20.0, 40.0, 50.0]
        waits = []

        on_console_wait(machine) do |timeout|
          waits << timeout
          clock[0] = wakeups.shift || raise('unexpected extra wait')
          machine.send(:append_console_output, "Kernel panic - not syncing: repeated panic\n")
        end

        machine.kill_after_kernel_failure(drain_timeout: 50)
        expect(waits).to eq([30.0, 30.0, 10.0])
        expect(clock.first).to eq(50.0)
        expect(machine).to be_kernel_failed
        expect { machine.raise_if_kernel_failed! }.to raise_error(OsVm::KernelFailure, /test panic/)
      end
    end

    it 'waits for recent output even when the original detection is older than the quiet interval' do
      with_failed_machine do |machine|
        clock[0] = 100.0
        machine.send(:append_console_output, "late dump output\n")

        on_console_wait(machine) do |timeout|
          expect(timeout).to eq(30.0)
          clock[0] += timeout
        end

        machine.kill_after_kernel_failure
        expect(clock.first).to eq(130.0)
      end
    end

    it 'stops draining immediately at console EOF' do
      with_failed_machine do |machine|
        waits = []

        on_console_wait(machine) do |timeout|
          waits << timeout
          clock[0] = 5.0
          machine.send(:append_console_output, '', flush: true)
        end

        machine.kill_after_kernel_failure
        expect(waits).to eq([30.0])
        expect(clock.first).to eq(5.0)
      end
    end

    it 'does not extend an expired hard deadline for recent output' do
      with_failed_machine do |machine|
        clock[0] = 7.0
        machine.send(:append_console_output, "recent output\n")
        cv = machine.instance_variable_get(:@console_cv)
        allow(cv).to receive(:wait) { raise 'unexpected console wait' }

        machine.kill_after_kernel_failure(drain_timeout: 5)
        expect(cv).not_to have_received(:wait)
      end
    end

    it 'supports immediate teardown with a zero drain timeout' do
      with_failed_machine do |machine|
        cv = machine.instance_variable_get(:@console_cv)
        allow(cv).to receive(:wait) { raise 'unexpected console wait' }

        machine.kill_after_kernel_failure(drain_timeout: 0)
        expect(cv).not_to have_received(:wait)
      end
    end

    it 'does not treat empty reads or spurious wakeups as new console activity' do
      with_failed_machine do |machine|
        wakeups = [15.0, 30.0]
        waits = []

        on_console_wait(machine) do |timeout|
          waits << timeout
          clock[0] = wakeups.shift || raise('unexpected extra wait')
          machine.send(:append_console_output, '')
        end

        machine.kill_after_kernel_failure
        expect(waits).to eq([30.0, 15.0])
      end
    end

    it 'resets console activity and EOF for the next machine start' do
      with_failed_machine do |machine|
        machine.send(:append_console_output, '', flush: true)
        machine.send(:reset_kernel_failure)
        expect(machine.instance_variable_get(:@console_last_output_at)).to be_nil
        expect(machine).not_to be_kernel_failed
        clock[0] = 20.0
        machine.send(:append_console_output, "Kernel panic - not syncing: new panic\n")
        waits = []

        on_console_wait(machine) do |timeout|
          waits << timeout
          clock[0] = 25.0
          machine.send(:append_console_output, '', flush: true)
        end

        machine.kill_after_kernel_failure
        expect(waits).to eq([30.0])
        expect { machine.raise_if_kernel_failed! }.to raise_error(OsVm::KernelFailure, /new panic/)
      end
    end

    it 'notifies console drain waiters about partial output and EOF' do
      with_tmpdir do |dir|
        machine = build_machine(dir:)
        cv = machine.instance_variable_get(:@console_cv)
        allow(cv).to receive(:broadcast).and_call_original

        machine.send(:append_console_output, 'a partial console line')
        machine.send(:append_console_output, '', flush: true)
        expect(cv).to have_received(:broadcast).twice
      end
    end
  end
end

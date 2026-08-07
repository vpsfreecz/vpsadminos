# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::MachineLog do
  def exited_process_status(status)
    pid = fork { exit(status) }
    Process.wait2(pid).last
  end

  def signaled_process_status(signal)
    pid = fork do
      Process.kill(signal, Process.pid)
      sleep
    end
    Process.wait2(pid).last
  end

  it 'records lifecycle actions and console waits' do
    with_tmpdir do |dir|
      path = File.join(dir, 'machine.log')
      log = described_class.new(path)

      log.start
      log.stop
      log.destroy
      log.kill('TERM')
      log.exit(exited_process_status(0))
      begun_at = log.console_wait_begin(/ready/)
      log.console_wait_end(true, nil, begun_at)
      log.close

      output = File.read(path)
      expect(output).to include('ACTION: start')
      expect(output).to include('ACTION: stop')
      expect(output).to include('ACTION: destroy')
      expect(output).to include('ACTION: kill')
      expect(output).to include('SIGNAL: TERM')
      expect(output).to include('ACTION: qemu_exit')
      expect(output).to include('STATUS: 0')
      expect(output).to include('ACTION: console-wait')
      expect(output).to include('MATCH: true')
      expect(output).to include('START:')
      expect(output).to include('END:')
      expect(output).to include('ELAPSED:')
    end
  end

  it 'records the terminating signal of a signaled qemu process' do
    with_tmpdir do |dir|
      path = File.join(dir, 'machine.log')
      log = described_class.new(path)

      log.exit(signaled_process_status('TERM'))
      log.close

      output = File.read(path)
      expect(output).to include("ACTION: qemu_exit\nSTATUS: \n")
      expect(output).to include('TERMSIG: 15')
      expect(output).to include('TERMSIG_NAME: SIGTERM')
      expect(output).to include('COREDUMP: false')
    end
  end
end

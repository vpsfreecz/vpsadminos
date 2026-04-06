# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::MachineLog do
  it 'records lifecycle actions and structured command events' do
    with_tmpdir do |dir|
      path = File.join(dir, 'machine.log')
      log = described_class.new(path)

      log.start
      log.stop
      log.destroy
      log.kill('TERM')
      log.exit(0)
      log.execute_begin('echo hello')
      log.execute_end(0, "hello\n")
      log.console_wait_begin(/ready/)
      log.console_wait_end(true)
      log.close

      output = File.read(path)
      expect(output).to include('ACTION: start')
      expect(output).to include('ACTION: stop')
      expect(output).to include('ACTION: destroy')
      expect(output).to include('ACTION: kill')
      expect(output).to include('SIGNAL: TERM')
      expect(output).to include('ACTION: qemu_exit')
      expect(output).to include('STATUS: 0')
      expect(output).to include('COMMAND: echo hello')
      expect(output).to include('OUTPUT:')
      expect(output).to include('ACTION: console-wait')
      expect(output).to include('MATCH: true')
      expect(output).to include('START:')
      expect(output).to include('END:')
      expect(output).to include('ELAPSED:')
    end
  end
end

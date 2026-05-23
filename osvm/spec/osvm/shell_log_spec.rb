# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::ShellLog do
  it 'records structured command events' do
    with_tmpdir do |dir|
      path = File.join(dir, 'shell.log')
      log = described_class.new(path, shell_name: 'first')

      begun_at = log.execute_begin('echo hello')
      log.execute_end(0, "hello\n", begun_at)
      log.close

      output = File.read(path)
      expect(output).to include('SHELL: first')
      expect(output).to include('COMMAND: echo hello')
      expect(output).to include('STATUS: 0')
      expect(output).to include('OUTPUT:')
      expect(output).to include("hello\n")
      expect(output).to include('START:')
      expect(output).to include('END:')
      expect(output).to include('ELAPSED:')
    end
  end
end

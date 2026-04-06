# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::Machine, '#kill' do
  it 'returns self when the machine is already stopped' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)

      expect(machine.kill).to eq(machine)
    end
  end
end

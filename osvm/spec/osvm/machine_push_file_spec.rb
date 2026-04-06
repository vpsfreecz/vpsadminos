# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::Machine, '#push_file' do
  it 'passes preserve through when pushing files' do
    with_tmpdir do |dir|
      machine = build_machine(dir:)
      shared_dir = instance_spy(OsVm::SharedDir)

      allow(machine).to receive(:mkdir_p)
      machine.instance_variable_set(:@shared_dir, shared_dir)

      expect(machine.push_file('/src', '/dst', preserve: true, mkpath: true)).to eq(machine)
      expect(shared_dir).to have_received(:push_file).with('/src', '/dst', preserve: true)
    end
  end
end

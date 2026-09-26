# frozen_string_literal: true

require 'spec_helper'
require File.expand_path('../../../tests/runner/extensions/vpsadminos_logs', __dir__)

RSpec.describe VpsadminosFailureLogs do
  it 'bounds kernel-stack collection to blocked and ZFS sync tasks' do
    script = described_class.diagnostics_script

    expect(script).to include('ps -eo pid=,stat=,comm=')
    expect(script).to include('$2 ~ /^D/ || $3 == "dp_sync_taskq"')
    expect(script).to include('head -n 16')
    expect(script).to include('timeout 2 cat "/proc/$pid/stack" 2>&1')
  end

  it 'retains collected output in the normal failure artifact' do
    machine = instance_double(OsVm::Machine, name: 'machine')
    output = "===== /proc/123/stack (D zfs) =====\n[<0>] zio_wait\n"

    allow(machine).to receive(:execute).and_return([0, output])

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'machine-failure-diagnostics.log')
      described_class.collect(machine, path)
      expect(File.read(path)).to include('status: 0', output)
    end

    expect(machine).to have_received(:execute).with(
      include('timeout 2 cat "/proc/$pid/stack"'),
      timeout: 300
    )
  end
end

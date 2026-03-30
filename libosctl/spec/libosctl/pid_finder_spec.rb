# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/exceptions'
require 'libosctl/pid_finder'

RSpec.describe OsCtl::Lib::PidFinder do
  it 'returns host and container results depending on the process cgroup' do
    host_process = instance_double(OsCtl::Lib::OsProcess, ct_id: nil)
    ct_process = instance_double(OsCtl::Lib::OsProcess, ct_id: %w[tank ct1])

    allow(OsCtl::Lib::OsProcess).to receive(:new).with(100).and_return(host_process)
    allow(OsCtl::Lib::OsProcess).to receive(:new).with(200).and_return(ct_process)

    expect(described_class.new.find(100)).to have_attributes(
      pool: nil,
      ctid: :host,
      os_process: host_process
    )

    expect(described_class.new.find(200)).to have_attributes(
      pool: 'tank',
      ctid: 'ct1',
      os_process: ct_process
    )
  end

  it 'returns nil when the process does not exist' do
    allow(OsCtl::Lib::OsProcess).to receive(:new).and_raise(
      OsCtl::Lib::Exceptions::OsProcessNotFound,
      'process 999 not found'
    )

    expect(described_class.new.find(999)).to be_nil
  end
end

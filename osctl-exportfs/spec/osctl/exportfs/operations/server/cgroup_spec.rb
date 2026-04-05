# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::CGroup do
  let(:server) { instance_double(OsCtl::ExportFS::Server, name: 'srv') }
  let(:cgroup) { instance_double(OsCtl::ExportFS::CGroup) }

  before do
    allow(OsCtl::ExportFS::CGroup).to receive(:new)
      .with('osctl/exportfs/server')
      .and_return(cgroup)
  end

  it 'enters and clears manager and payload cgroups' do
    allow(cgroup).to receive_messages(create: nil, enter: nil, destroy: nil, kill_all_until_empty: nil)

    op = described_class.new(server)
    op.enter_manager
    op.enter_payload
    op.clear_manager
    op.clear_payload

    expect(cgroup).to have_received(:create).with('srv/manager')
    expect(cgroup).to have_received(:enter).with('srv/manager')
    expect(cgroup).to have_received(:create).with('srv/payload')
    expect(cgroup).to have_received(:enter).with('srv/payload')
    expect(cgroup).to have_received(:kill_all_until_empty).with('srv/payload')
    expect(cgroup).to have_received(:destroy).with('srv/manager')
    expect(cgroup).to have_received(:destroy).with('srv/payload')
  end

  it 'swallows missing cgroups when clearing all' do
    allow(cgroup).to receive(:destroy).and_raise(Errno::ENOENT)
    allow(cgroup).to receive(:kill_all_until_empty).and_raise(Errno::ENOENT)

    expect { described_class.new(server).clear_all }.not_to raise_error
  end
end

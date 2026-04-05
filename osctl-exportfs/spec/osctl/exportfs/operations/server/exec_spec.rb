# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::Exec do
  let(:server) { instance_double(OsCtl::ExportFS::Server, running?: true, read_pid: 4321) }
  let(:cgroup) { instance_double(OsCtl::ExportFS::Operations::Server::CGroup, enter_payload: nil) }
  let(:sys) { build_fake_sys }

  before do
    allow(OsCtl::ExportFS::Operations::Server::CGroup).to receive(:new).with(server).and_return(cgroup)
    allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)
  end

  it 'refuses to execute when the server is not running' do
    allow(server).to receive(:running?).and_return(false)

    expect { described_class.run(server) { nil } }.to raise_error(
      RuntimeError,
      'the server is not running'
    )
  end

  it 'opens namespace files, joins them, and runs a successful block' do
    ios = %w[mnt net uts ipc pid].to_h do |ns|
      [ns, StringIO.new]
    end
    %w[mnt net uts ipc pid].each do |ns|
      allow(File).to receive(:open).with("/proc/4321/ns/#{ns}", 'r').and_return(ios.fetch(ns))
    end

    pids = [101, 202]
    allow(Process).to receive(:fork) do |&block|
      pid = pids.shift
      block.call
      pid
    end
    allow(Process).to receive(:wait2).with(202).and_return([202, build_wait_status(0)])
    allow(Process).to receive(:wait2).with(101).and_return([101, build_wait_status(0)])

    block_ran = false
    described_class.run(server) { block_ran = true }

    expect(block_ran).to be(true)
    expect(sys).to have_received(:setns_io).with(ios['mnt'], OsCtl::Lib::Sys::CLONE_NEWNS)
    expect(sys).to have_received(:setns_io).with(ios['net'], OsCtl::Lib::Sys::CLONE_NEWNET)
    expect(sys).to have_received(:setns_io).with(ios['uts'], OsCtl::Lib::Sys::CLONE_NEWUTS)
    expect(sys).to have_received(:setns_io).with(ios['ipc'], OsCtl::Lib::Sys::CLONE_NEWIPC)
    expect(sys).to have_received(:setns_io).with(ios['pid'], OsCtl::Lib::Sys::CLONE_NEWPID)
  end

  it 'propagates a non-zero exit status from the block' do
    allow(server).to receive(:read_pid).and_return(Process.pid)

    expect do
      described_class.run(server) { Process.exit!(7) }
    end.to raise_error(RuntimeError, 'server exec failed with exit status 7')
  end

  it 'propagates block exceptions as a failed execution' do
    allow(server).to receive(:read_pid).and_return(Process.pid)

    expect do
      described_class.run(server) { raise 'boom' }
    end.to raise_error(RuntimeError, 'server exec failed with exit status 1')
  end
end

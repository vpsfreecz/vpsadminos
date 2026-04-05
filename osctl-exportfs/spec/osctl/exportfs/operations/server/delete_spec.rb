# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::Delete do
  it 'refuses to delete a running server' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = OsCtl::ExportFS::Server.new('srv')
      FileUtils.mkdir_p(server.dir)
      allow(server).to receive(:synchronize).and_yield
      allow(server).to receive(:running?).and_return(true)
      allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)

      expect { described_class.run('srv') }.to raise_error(RuntimeError, 'the server is running')
    end
  end

  it 'cleans up leftover shared mounts, ignores unmount errors, and removes the server tree' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = OsCtl::ExportFS::Server.new('srv')
      FileUtils.mkdir_p(server.shared_dir)
      FileUtils.mkdir_p(server.nfs_state)
      FileUtils.mkdir_p(File.join(server.shared_dir, 'one'))
      FileUtils.mkdir_p(File.join(server.shared_dir, 'two'))
      allow(server).to receive(:synchronize).and_yield
      allow(server).to receive(:running?).and_return(false)
      allow(OsCtl::ExportFS::Server).to receive(:new).with('srv').and_return(server)

      sys = build_fake_sys
      allow(sys).to receive(:unmount).with(File.join(server.shared_dir, 'one')).and_raise(Errno::EINVAL)
      allow(sys).to receive(:unmount).with(File.join(server.shared_dir, 'two')).and_return(nil)
      allow(sys).to receive(:unmount).with(server.shared_dir).and_raise(Errno::EINVAL)
      allow(OsCtl::Lib::Sys).to receive(:new).and_return(sys)

      cgroup = instance_double(OsCtl::ExportFS::Operations::Server::CGroup, clear_all: nil)
      allow(OsCtl::ExportFS::Operations::Server::CGroup).to receive(:new).with(server).and_return(cgroup)

      described_class.run('srv')

      expect(Dir.exist?(server.dir)).to be(false)
      expect(cgroup).to have_received(:clear_all)
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Server do
  it 'builds host and namespace-relative paths' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = described_class.new('srv')

      expect(server.dir).to eq(File.join(OsCtl::ExportFS::RunState::SERVERS, 'srv'))
      expect(server.shared_dir).to eq(File.join(server.dir, 'shared'))

      server.enter_ns
      expect(server.dir).to eq(OsCtl::ExportFS::RunState::CURRENT_SERVER)
      expect(server.config_file).to eq(File.join(OsCtl::ExportFS::RunState::CURRENT_SERVER, 'config.yml'))

      server.leave_ns
      expect(server.dir).to eq(File.join(OsCtl::ExportFS::RunState::SERVERS, 'srv'))
    end
  end

  it 'reads pid values from the pid file' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = described_class.new('srv')
      FileUtils.mkdir_p(server.dir)
      File.write(server.pid_file, "123\n")

      expect(server.read_pid).to eq(123)
    end
  end

  it 'detects missing, empty, live, and stale pid files' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = described_class.new('srv')
      FileUtils.mkdir_p(server.dir)

      expect(server.running?).to be(false)

      File.write(server.pid_file, '')
      expect(server.running?).to be(false)

      File.write(server.pid_file, '123')
      stub_pid_signalability(live_pids: [123])
      expect(server.running?).to be(true)

      stub_pid_signalability
      expect(server.running?).to be(false)
    end
  end

  it 'supports nested synchronization on the same server instance' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      server = described_class.new('srv')

      calls = 0
      allow(server).to receive(:Filelock) do |_path, &block|
        calls += 1
        block.call
      end

      ret = server.synchronize do
        server.synchronize { :ok }
      end

      expect(ret).to eq(:ok)
      expect(calls).to eq(1)
    end
  end
end

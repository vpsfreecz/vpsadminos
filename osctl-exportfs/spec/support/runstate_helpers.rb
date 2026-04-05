# frozen_string_literal: true

module RunstateHelpers
  def stub_exportfs_runstate(root)
    stub_const('OsCtl::ExportFS::RunState::DIR', root)
    stub_const('OsCtl::ExportFS::RunState::RUNSVDIR', File.join(root, 'runsvdir'))
    stub_const('OsCtl::ExportFS::RunState::CURRENT_SERVER', File.join(root, 'current-server'))
    stub_const('OsCtl::ExportFS::RunState::SERVERS', File.join(root, 'servers'))
    stub_const('OsCtl::ExportFS::RunState::ROOTFS', File.join(root, 'rootfs'))
  end

  def prepare_exportfs_runstate(root)
    stub_exportfs_runstate(root)
    FileUtils.mkdir_p(OsCtl::ExportFS::RunState::RUNSVDIR)
    FileUtils.mkdir_p(OsCtl::ExportFS::RunState::SERVERS)
    FileUtils.mkdir_p(OsCtl::ExportFS::RunState::ROOTFS)
  end
end

RSpec.configure do |config|
  config.include RunstateHelpers
end

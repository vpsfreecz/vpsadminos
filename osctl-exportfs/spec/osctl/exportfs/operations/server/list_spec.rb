# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Operations::Server::List do
  it 'returns an empty list when no servers exist' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)

      expect(described_class.run).to eq([])
    end
  end

  it 'returns server objects for each server directory' do
    with_tmpdir do |tmpdir|
      prepare_exportfs_runstate(tmpdir)
      FileUtils.mkdir_p(File.join(OsCtl::ExportFS::RunState::SERVERS, 'alpha'))
      FileUtils.mkdir_p(File.join(OsCtl::ExportFS::RunState::SERVERS, 'beta'))

      expect(described_class.run.map(&:name)).to contain_exactly('alpha', 'beta')
    end
  end
end

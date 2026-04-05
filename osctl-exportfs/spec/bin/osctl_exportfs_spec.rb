# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::ExportFS::Cli do
  it 'loads the CLI entrypoint and delegates to Cli.run' do
    allow(described_class).to receive(:run)

    load File.join(REPO_ROOT, 'osctl-exportfs', 'bin', 'osctl-exportfs')

    expect(described_class).to have_received(:run)
  end
end

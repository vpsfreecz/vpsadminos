# frozen_string_literal: true

require 'osctl/repo'
require 'osctl/repo/cli'

RSpec.describe OsCtl::Repo do
  it 'loads the library entrypoint' do
    expect(defined?(OsCtl::Repo::Base::Image)).to eq('constant')
    expect(defined?(OsCtl::Repo::Local::Repository)).to eq('constant')
    expect(defined?(OsCtl::Repo::Remote::Repository)).to eq('constant')
  end

  it 'loads the cli entrypoint' do
    expect(defined?(OsCtl::Repo::Cli::App)).to eq('constant')
    expect(defined?(OsCtl::Repo::Cli::Repo)).to eq('constant')
  end
end

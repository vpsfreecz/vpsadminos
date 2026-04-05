# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Image::Cli::App do
  it 'sets up the CLI without raising' do
    app = described_class.new

    expect { app.setup }.not_to raise_error
  end

  it 'registers the expected top-level commands and ct subcommands' do
    app = described_class.new
    app.setup

    expect(app.commands.keys.map(&:to_s)).to include('ls', 'build', 'test', 'instantiate', 'deploy', 'ct')
    expect(app.commands[:ct].commands.keys.map(&:to_s)).to include('ls', 'del')
  end
end

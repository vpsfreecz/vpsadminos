# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Cli::App do
  it 'builds the command tree and default command' do
    app = described_class.get

    expect(app.commands.keys.map(&:to_s)).to include('ls', 'test', 'debug')
  end
end

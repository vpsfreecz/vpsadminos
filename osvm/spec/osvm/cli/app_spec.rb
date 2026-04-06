# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsVm::Cli::App do
  it 'builds the command tree' do
    app = described_class.get

    expect(app.commands.keys.map(&:to_s)).to include('script')
  end
end

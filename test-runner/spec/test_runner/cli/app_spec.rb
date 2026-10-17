# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TestRunner::Cli::App do
  it 'builds the command tree and default command' do
    app = described_class.get

    expect(app.commands.keys.map(&:to_s)).to include('ls', 'test', 'debug')
    %w[test debug].each do |name|
      expect(app.commands[name.to_sym].switches[:f].aliases.map(&:to_s)).to include('fresh')
    end
  end

  it 'describes runtime scheduling independently of the prebuild switch' do
    description = described_class.get.commands[:test].switches[:prebuild].description
    expect(description).to include('runtime resource scheduling')
    expect(description).not_to include('memory admission')
  end

  [[], ['--prebuild'], ['--no-prebuild']].each do |flags|
    it "parses prebuild selection #{flags.inspect} with an opt-in default" do
      selected = nil
      allow(TestRunner::Cli::Command).to receive(:run).and_call_original
      allow(TestRunner::Cli::Command).to receive(:run).with(:test).and_return(
        proc { |_global, opts, _args| selected = opts }
      )
      expect(described_class.get.run(['test', *flags])).to eq(0)
      expect(selected.fetch('prebuild')).to eq(flags == ['--prebuild'])
      expect(selected.fetch('prebuild-memory-per-job-mib')).to eq(8192)
    end
  end
end
